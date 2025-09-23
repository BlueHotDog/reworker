# Re-WebWorker

> **Type-safe, chunked message passing for WebWorkers, ServiceWorkers, and browser extensions with zero runtime dependencies**

**@bluehotdog/re-webworker** is a ReScript library that provides type-safe communication across JavaScript contexts using GADTs (Generalized Algebraic Data Types), automatic message chunking, and framework-agnostic bindings.

## Core Problem

WebWorkers, ServiceWorkers, and browser extensions need message passing between contexts with:
- Size limits requiring manual chunking
- No compile-time type safety
- Framework-specific implementations
- Complex async response handling

## Solution

```rescript
// Define messages with exact response types
type Types.message<_> +=
  | GetUserProfile(string): Types.message<Result.t<User.Profile.t, string>>
  | ProcessLargeData(array<bigObject>): Types.message<Result.t<summary, error>>

// Send messages - chunking and type safety automatic
MyRuntime.sendMessage(GetUserProfile("user123"), response => {
  // response is typed as Result.t<User.Profile.t, string>
  Console.log(response)
})
```

## Features

### Type Safety with GADTs
- Each message constructor defines its response type
- Compile-time verification of request-response pairs
- No runtime type errors

### Automatic Chunking
- Handles Chrome's message size limits transparently
- Automatic reassembly on receiving end
- No configuration required

### Framework Agnostic
- Works with any Chrome extension framework
- Uses functor pattern - pass your native bindings to `Runtime.Make`
- No adapters or wrappers needed
- Zero runtime dependencies

### Production Ready
- Comprehensive test suite
- Handles chunk failures and timeouts
- Used in production extensions

## 📦 Installation

```bash
npm install @bluehotdog/re-webworker
```

**Requirements:**
- ReScript ^12.0.0-beta.12
- JavaScript environment with message passing support (WebWorkers, ServiceWorkers, browser extensions)

## 🔧 Quick Start

### 1. Define Your Messages
```rescript
// In your shared types file
type Types.message<_> +=
  | GetUserSettings: Types.message<UserSettings.t>
  | SaveDocument(string): Types.message<Result.t<unit, string>>
  | ProcessData(array<dataPoint>): Types.message<ProcessResult.t>
```

### 2. Create Runtime Instance with Clean Client API
```rescript
// Create the re-webworker Runtime instance using WXT bindings directly
module AppRuntime = Runtime.Make(WxtRuntime)

// Use re-webworker Runtime for message sending with Promise wrapper
let sendMessageToSelf: type a. Types.message<a> => promise<a> = message => {
  let promise = Promise.make((resolve, _reject) => {
    AppRuntime.sendMessage(message, response => {
      resolve(response)
    })
  })
  promise
}

// Clean Client module for your extension's API
module Client = {
  let getUserSettings = () => {
    sendMessageToSelf(GetUserSettings)
  }

  let saveDocument = content => {
    sendMessageToSelf(SaveDocument(content))
  }

  let processData = dataPoints => {
    sendMessageToSelf(ProcessData(dataPoints))
  }
}
```

### 3. Handle Messages in Background Script
```rescript
let listener: type a. (Types.message<a>, Bindings__Browser.Runtime.sender) => Response.t<a> =
  (msg, _sender) => {
    switch msg {
    | GetUserSettings =>
      Response.later(Database.getUserSettings())
    | SaveDocument(content) => {
        let saveOperation = async () => {
          await Database.saveDocument(content)
          Ok()
        }
        Response.later(saveOperation())
      }
    | ProcessData(dataPoints) => {
        let processOperation = async () => {
          await Analytics.processLargeDataset(dataPoints)
        }
        Response.later(processOperation())
      }
    | _ => Response.none
    }
  }

let main = () => {
  AppRuntime.OnMessage.addListener(listener)
}
```

### 4. Use from Content Scripts, Popup, etc.
```rescript
// In your content script or popup
let handleUserAction = async () => {
  // All calls return properly typed promises
  let settings = await Client.getUserSettings()
  let saveResult = await Client.saveDocument("document content")
  let processResult = await Client.processData(largeDataArray)

  // Type-safe responses - no runtime type checking needed!
  switch saveResult {
  | Ok() => showSuccess("Document saved!")
  | Error(msg) => showError(msg)
  }
}
```

## 🏗️ Architecture

```
User Level                             Transport Level              Receiving Side
┌────────────────────────────────┐    ┌─────────────────┐          ┌─────────────────┐
│ Client.getUserSettings()       │───▶│ Auto-chunking   │─────────▶│ Auto-reassembly │
│ returns Promise<UserSettings.t>│    │ if > threshold  │          │ + type safety   │
└────────────────────────────────┘    └─────────────────┘          └─────────────────┘
```

**Key Components:**
- **Types.res** - GADT message definitions
- **Runtime.res** - Main messaging runtime with framework bindings
- **TransportMessage.res** - Internal chunking layer (completely hidden from users)
- **RequestHandler.res** - Chunk reassembly and message forwarding
- **Response.res** - Type-safe response patterns

## 🔌 Framework Integration: Functor-Based Bindings

Re-WebWorker uses `Runtime.Make(YourBindings)` to integrate with any messaging system - WebWorkers, ServiceWorkers, or browser extensions. The functor takes your native bindings and adds type safety, chunking, and message handling.

### RuntimeBindings Interface

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

This matches standard JavaScript message passing patterns. No adapters needed.

### Browser Extensions (WXT Framework)
```rescript
module AppRuntime = Runtime.Make(WxtRuntime)
```

### Browser Extensions (Raw Chrome APIs)
```rescript
module ChromeBindings = {
  type sender = Chrome.Runtime.MessageSender.t
  let sendMessage = (msg, callback) => Chrome.Runtime.sendMessage(msg, callback)
  module OnMessage = {
    let addListener = Chrome.Runtime.OnMessage.addListener
    let removeListener = Chrome.Runtime.OnMessage.removeListener
  }
  let getRuntimeId = () => Chrome.Runtime.id
}
module AppRuntime = Runtime.Make(ChromeBindings)
```

### Web Workers
```rescript
module WorkerBindings = {
  type sender = unit // Workers don't have sender context
  let sendMessage = (msg, callback) => {
    // Post to main thread and listen for response
    postMessage(msg)
    onmessage = event => callback(event.data)
  }
  module OnMessage = {
    let addListener = handler => {
      onmessage = event => {
        let shouldRespond = handler(event.data, (), response => postMessage(response))
        shouldRespond
      }
    }
    let removeListener = _ => onmessage = _ => ()
  }
  let getRuntimeId = () => Some("worker")
}
module WorkerRuntime = Runtime.Make(WorkerBindings)
```

### Service Workers
```rescript
module ServiceWorkerBindings = {
  type sender = {clientId: string}
  let sendMessage = (msg, callback) => {
    // Send to all clients and handle responses
    clients.matchAll().then(clientList => {
      clientList->Array.forEach(client => client.postMessage(msg))
    })
  }
  module OnMessage = {
    let addListener = handler => {
      addEventListener("message", event => {
        let sender = {clientId: event.source.id}
        handler(event.data, sender, response => event.source.postMessage(response))
      })
    }
    let removeListener = _ => () // Remove specific listeners as needed
  }
  let getRuntimeId = () => Some("service-worker")
}
module SWRuntime = Runtime.Make(ServiceWorkerBindings)
```

### Any Framework
Implement `RuntimeBindings` with your messaging system's APIs. Same interface regardless of environment.

## 🎯 Real-World Example: AI-Powered Browser Extension

```rescript
// Background.res - AI Language Model Integration
module AppRuntime = Runtime.Make(WxtRuntime)

type Types.message<_> +=
  | LanguageModelAvailability: Types.message<Bindings__LanguageModel.availability>
  | SubmitPrompt(string): Types.message<Js.Json.t>

let session: ref<option<Bindings__LanguageModel.Session.t>> = ref(None)

let getSession = async () => {
  let newSession = switch session.contents {
  | None =>
    await Bindings__LanguageModel.create({
      initialPrompts: [{
        role: Bindings__LanguageModel.System,
        content: "You are a helpful assistant for task management.",
      }],
    })
  | Some(session) => session
  }
  session := Some(newSession)
  newSession
}

let sendMessageToSelf: type a. Types.message<a> => promise<a> = message => {
  let promise = Promise.make((resolve, _reject) => {
    AppRuntime.sendMessage(message, response => {
      resolve(response)
    })
  })
  promise
}

module Client = {
  let languageModelAvailability = () => {
    sendMessageToSelf(LanguageModelAvailability)
  }
  let submitPrompt = prompt => {
    sendMessageToSelf(SubmitPrompt(prompt))
  }
}

let listener: type a. (Types.message<a>, Bindings__Browser.Runtime.sender) => Response.t<a> =
  (msg, _sender) => {
    switch msg {
    | LanguageModelAvailability =>
      Response.later(Bindings__LanguageModel.availability())
    | SubmitPrompt(prompt) => {
        let promptRequest = async () => {
          let activeSession = await getSession()
          await activeSession->Bindings__LanguageModel.prompt(~prompt, ~promptOpts={responseConstraint: schema})
        }
        Response.later(promptRequest())
      }
    | _ => Response.none
    }
  }

let main = () => {
  AppRuntime.OnMessage.addListener(listener)
}
```

## 📚 Advanced Features

### Message Extensions Across Packages
```rescript
// Package A defines base messages
type Types.message<_> += | CoreMessage(string): Types.message<string>

// Package B extends with new messages
type Types.message<_> += | AdvancedMessage(data): Types.message<Result.t<response, error>>
```

### Custom Response Patterns
```rescript
let asyncHandler = (msg, sender) => {
  switch msg {
  | LongRunningTask(params) =>
    processAsync(params)
    ->Promise.thenResolve(result => Response.now(result))
  | StreamingData(request) =>
    Response.streaming(dataStream)  // For real-time data
  | _ => Response.none
  }
}
```

### Error Handling
```rescript
let handleUserAction = async () => {
  try {
    let result = await Client.riskyOperation(data)
    switch result {
    | Ok(success) => handleSuccess(success)
    | Error(msg) => showError(msg)
    }
  } catch {
  | exn => showError("Network error: " ++ exn->Js.String.make)
  }
}
```

## 🧪 Testing

```bash
cd packages/re-webworker
make test
```

The library includes comprehensive tests covering:
- GADT type safety verification
- Message chunking and reassembly
- Framework binding compatibility
- Error handling and edge cases

## 🔍 Debugging

Use Chrome DevTools in each extension context:
- **Background Script**: Check chunking logic and message routing
- **Content Script**: Monitor message sending and response handling
- **Popup/Sidepanel**: Debug UI-triggered communications

ReScript values compile to stable JavaScript objects, making debugging straightforward.

## 📈 Performance

- **Zero runtime overhead** for small messages
- **Efficient chunking** only when needed (configurable threshold)
- **Minimal memory footprint** - no external dependencies
- **Fast compilation** with ReScript's optimized output

## 🤝 Contributing

1. **Issues**: Report bugs or request features via GitHub issues
2. **Development**: Follow the agent specialization guide in `AGENTS.md`
3. **Testing**: All PRs must include tests and pass existing test suite

## 📄 License

MIT License - use freely in commercial and open source projects.

---

Type-safe Chrome extension communication with automatic chunking and framework independence.
