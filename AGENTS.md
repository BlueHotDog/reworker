# ReWorker - Universal Message Passing Library

**@bluehotdog/reworker** is a ReScript library providing type-safe, chunked message passing for WebWorkers, ServiceWorkers, and browser extensions using GADTs (Generalized Algebraic Data Types).

## Core Features

### 1. Type-Safe Message Passing with GADTs
- **GADT Definition**: `type rec message<_> = ..` in `src/Types.res` enables fully typed request-response pairs
- **Type Safety**: Each message type statically defines its expected response type
- **Extensible**: Messages can be extended across packages using `type Types.message<_> += ...`

### 2. Chunked Message Support
- **Unlimited Size**: Automatically chunks large messages to bypass Chrome extension size limits
- **Transparent**: Chunking happens automatically when messages exceed threshold
- **Reassembly**: Automatic message reconstruction on the receiving end

## Architecture Overview

```
src/
├── Types.res              # GADT message type definitions
├── Runtime.res            # Main messaging runtime with functor-based bindings
├── TransportMessage.res   # Internal transport layer for chunking
├── RequestHandler.res     # Chunk reassembly and message forwarding
├── MessageChunker.res     # Core chunking functionality with internal Chunk module
├── Response.res           # Generic response types for Chrome extension patterns
└── Id.res                # Opaque UUID generation for chunk tracking
```

## Development Agent Specializations

### GADT Message System Agent
**Use this agent for**: Defining new message types, type safety issues, extending message variants

**Key Concepts**:
- GADTs allow each message constructor to specify its response type
- Example: `| GetUser(string): Types.message<User.t>`
- Response type is encoded in the message type itself
- Enables compile-time verification of request-response pairs

**Common Tasks**:
- Add new message variants with proper response types
- Fix GADT type inference issues
- Extend message types across packages
- Debug message type mismatches

### Transport Layer Agent
**Use this agent for**: Internal chunking implementation, transport message processing, chunk reassembly

**CRITICAL: TransportMessage is Completely Internal**:
- **Users never see TransportMessage.t** - it's purely an internal implementation detail
- **Native bindings work with raw ReScript values** - no knowledge of transport types needed
- **Runtime.Make handles all conversion** - user types ↔ transport types ↔ native bindings

**How Transport Chunking Works**:
- Messages over threshold are automatically chunked by `Runtime.Make` functor
- **Internal-only**: Transport layer uses `TransportMessage.t<'response>` types separate from user messages
- Three transport message variants (all internal):
  - `UserMessage(message)` - Direct small messages
  - `IntermediateChunk(chunk): t<chunkAck>` - Mid-transfer chunks expecting acknowledgment
  - `FinalChunk(chunk): t<'response>` - Last chunk expecting original response type
- **User experience**: Send `GetUser("123")`, receive `User.t` - chunking is invisible

**Transport Flow Architecture**:
```
User Level:                     Transport Level:                 Receiving Side:
┌─────────────────┐            ┌─────────────────┐              ┌─────────────────┐
│ GetUser("123")  │  Runtime   │ Check size      │              │ RequestHandler  │
│                 │ ────────▶  │ >31MB? Chunk    │              │ (Reassembly)    │
└─────────────────┘            └─────────┬───────┘              └─────────┬───────┘
                                         │                                │
                                         ▼                                ▼
                               ┌─────────────────┐              ┌─────────────────┐
                               │ IntermediateChunk│ JSON        │ Collect chunk   │
                               │ chunk #1        │────────────▶│ Ack: ChunkAck   │
                               └─────────────────┘              └─────────────────┘
                                         │                                │
                                         ▼                                ▼
                               ┌─────────────────┐              ┌─────────────────┐
                               │ IntermediateChunk│ JSON        │ Collect chunk   │
                               │ chunk #2        │────────────▶│ Ack: ChunkAck   │
                               └─────────────────┘              └─────────────────┘
                                         │                                │
                                         ▼                                ▼
                               ┌─────────────────┐              ┌─────────────────┐
                               │ FinalChunk      │ JSON        │ Reassemble      │
                               │ chunk #3        │────────────▶│ Call user handler│
                               └─────────────────┘              │ Return: User.t  │
                                                                └─────────────────┘
```

**Key Files**:
- `TransportMessage.res` - Transport message types with different response type constraints
- `Runtime.res` - Handles automatic chunking using generic bindings interface
- `RequestHandler.res` - Processes transport messages and reassembles chunks
- `MessageChunker.res` - Core chunking utilities

**Type Structure**:
- `TransportMessage.t<'response>` - GADT for transport messages with typed responses
- `TransportMessage.chunk` - Individual chunk with `{messageId, index, total, body}`
- `TransportMessage.chunkAck` - Acknowledgment type for intermediate chunks

**Common Tasks**:
- Adjust chunk size limits
- Debug chunk reassembly failures
- Handle chunk timeout/retry logic
- Optimize chunking performance

### Runtime Bindings Agent
**Use this agent for**: Creating browser bindings, integrating with different Chrome extension frameworks

**Manifest V3 Promise-Based Design**:
We're targeting Manifest V3 extensions, which means we can work purely with promises rather than legacy callback patterns. This simplifies the API significantly.

**Native Chrome API Interface**:
The Runtime uses a native Chrome API pattern for maximum compatibility:
```rescript
module type RuntimeBindings = {
  type sender
  let sendMessage: ('a, 'b => unit) => unit
  module OnMessage: {
    let addListener: (('a, sender, 'b => unit) => bool) => unit
    let removeListener: (('a, sender, 'b => unit) => bool) => unit
  }
  let getRuntimeId: unit => option<string>
}
```

**Key Design**: This interface matches Chrome's native `onMessage` pattern exactly:
- Handlers receive `(message, sender, sendResponse)`
- Return `bool` indicating if response will be sent asynchronously
- No forced `Response.t` types - bindings stay native
- **Manifest V3**: Promise-based APIs enable cleaner async patterns without callback complexity

**Integration Examples**:
- **Web Workers**: Use `postMessage`/`onmessage` APIs
- **Service Workers**: Use client messaging APIs
- **WXT Framework**: Use `@packages/bindings-wxt/src/WxtRuntime.res`
- **WebExtension-API**: Create similar bindings using `browser.runtime`
- **Raw Chrome APIs**: Bind directly to `chrome.runtime` APIs
- **Manifest V3**: All Chrome extension APIs now return promises, simplifying async handling

**Communication Patterns**:
- **Native bindings**: Use standard JavaScript message passing patterns
- **Internal conversion**: Runtime.Make converts user `Response.t` handlers to callback pattern
- **No adapters needed**: Pass native bindings directly to Runtime.Make
- **Automatic chunking**: All chunking handled internally via TransportMessage system
- **Type safety**: ReScript values pass through as stable JavaScript objects
- **Promise-based**: Manifest V3 eliminates callback complexity with native promise support

**Common Tasks**:
- Create new framework bindings using the native RuntimeBindings interface
- Handle browser-specific API differences (WXT vs raw Chrome APIs)
- Implement custom sender types for different contexts
- Debug callback vs Response.t conversion issues
- Leverage Manifest V3 promise patterns for cleaner async code

### ReScript v12 Compilation Agent
**Use this agent for**: ReScript compilation issues, module system, ES module output

**Package Configuration**:
- ESModule output: `"module": "esmodule"`
- In-source compilation: `"in-source": true`
- Custom suffix: `".res.mjs"`
- No dependencies (pure ReScript library)

**Common Issues**:
- GADT type inference failures
- Module import/export problems
- Compilation errors with bleeding-edge ReScript features
- Interface file (`.resi`) synchronization

## Usage Patterns

### Defining New Messages
```rescript
// In any package that depends on reworker
type Types.message<_> +=
  | GetUserProfile(string): Types.message<Result.t<User.Profile.t, string>>
  | UpdateSettings(Settings.t): Types.message<Result.t<unit, string>>
```

### Creating Runtime Instance
```rescript
// Use native bindings directly - no adapters needed!
module MyRuntime = Runtime.Make(WxtRuntime)

// Or create custom bindings using Chrome's callback pattern:
module MyBindings = {
  type sender = // your sender type
  let sendMessage = // your sendMessage implementation
  module OnMessage = {
    let addListener = // (message, sender, sendResponse) => bool
    let removeListener = // (message, sender, sendResponse) => bool
  }
  let getRuntimeId = // your runtime ID check
}

module MyRuntime = Runtime.Make(MyBindings)
```

### Sending Messages
```rescript
// Automatic chunking if message is large
MyRuntime.sendMessage(GetUserProfile("user123"), response => {
  // Response type is inferred as Result.t<User.Profile.t, string>
  Console.log(response)
})

// Fire-and-forget messages
MyRuntime.cast(UpdateSettings(newSettings))
```

### Handling Messages
```rescript
let handler = (msg, sender) => {
  switch msg {
  | GetUserProfile(userId) =>
    // Handler knows response must be Result.t<User.Profile.t, string>
    let profile = User.getProfile(userId)
    Response.now(Ok(profile))
  | UpdateSettings(settings) =>
    saveSettings(settings)
    Response.now(Ok())
  | _ => Response.none
  }
}

MyRuntime.OnMessage.addListener(handler)
```

## Development Workflows

### Adding New Message Types
1. Extend `Types.message<_>` in your package
2. Add handler case in message listener
3. Update sender code to use new message type
4. Test with both small and large payloads to verify chunking

### Creating New Browser Bindings
1. Implement `RuntimeBindings` using Chrome's native callback pattern
2. Pass bindings directly to `Runtime.Make(YourBindings)` - no adapters needed
3. Runtime handles all Response.t ↔ callback conversion internally
4. Test with your framework's specific APIs

### Testing Chunking
1. Create test messages larger than chunking threshold
2. Verify `TransportMessage` variants are used internally
3. Test chunk reassembly and response forwarding
4. Handle network failures during chunking

### Debugging Communication
1. Use Chrome DevTools in each extension context
2. Monitor messages at transport layer (ReScript values compile to stable JavaScript objects)
3. Check chunk metadata and reassembly logic
4. Verify GADT types match between sender and receiver
5. Debug generic type flow through bindings interface

## Dependencies and Integration

**Zero Dependencies**: Pure ReScript library with no runtime dependencies
**Peer Dependencies**: ReScript ^12.0.0-beta.12
**Integration**: Works with any messaging system via native callback RuntimeBindings
**Zero Adapters**: Pass native bindings directly to Runtime.Make, no wrapper code needed
**Type-Safe**: ReScript values compile to stable JavaScript objects, automatic Response.t conversion

## Key Constraints

- **JavaScript Message Passing**: Designed for environments with message passing capabilities (WebWorkers, ServiceWorkers, browser extensions)
- **Manifest V3 Extensions**: Targets modern Chrome extensions with promise-based APIs
- **ReScript v12**: Uses bleeding-edge ReScript features (GADTs, JSX v4)
- **No Runtime Deps**: Must remain dependency-free for maximum compatibility
- **Type Safety First**: All features prioritize compile-time type safety

Remember: This is a foundational library - changes here affect all packages that depend on it. Always consider backward compatibility and type safety when making modifications.
