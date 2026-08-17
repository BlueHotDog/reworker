# ReWorker

Type-safe message passing for browser windows, workers, and extensions with automatic chunking. Zero dependencies.

## Install

```bash
npm install @bluehotdog/reworker
```

## Usage

Define messages with GADTs:
```rescript
type Types.message<_> +=
  | GetUser(string): Types.message<User.t>
  | SaveData(data): Types.message<Result.t<unit, string>>
```

Create one runtime for each transport, then send messages:
```rescript
let runtime = Runtime.make(transport)

// Promise-based API
Runtime.sendMessage(runtime, GetUser("123"))->Promise.then(user => Console.log(user))

// With async/await
let user = await Runtime.sendMessage(runtime, GetUser("123"))
Console.log(user)

// Fire-and-forget
Runtime.cast(runtime, SaveData(userData))
```

Handle messages:
```rescript
let handler = (msg, _sender, signal) => {
  switch msg {
  | GetUser(id) => Response.now(Database.getUser(id))
  | SaveData(data) => Response.now(Database.save(data))
  | _ => Response.none
  }
}
Runtime.OnMessage.addListener(runtime, handler)
```

Each runtime owns one message handler. Registering a different second handler throws; compose domain-specific handlers in application code before registration.

Transport values provide an ordered duplex connection. Reworker owns request correlation, timeouts, remote errors, casts, and chunking. Each value owns independent listener, request, and chunk state.

```rescript
let transport: Runtime.transport<'sender, 'extension> = {
  requestTimeoutMs: 5000,
  maxMessageBytes: 32_000_000,
  maxPendingRequests: 100,
  maxChunkBytes: 1_000_000,
  postMessage,
  addMessageListener,
  removeMessageListener,
  addOpenListener,
  removeOpenListener,
  addCloseListener,
  removeCloseListener,
  isOpen,
  isCurrentSender,
  senderKey,
  close,
  extension,
}
```

`postMessage` must return `Error` when structured clone fails. Close listeners must fire when the remote endpoint becomes unavailable so pending requests reject immediately. `senderKey` must return the same stable key for events from one logical sender, even when the environment creates new sender objects. `extension` holds environment-specific state and operations.

Resource limits are mandatory and must be positive. `maxMessageBytes` rejects oversized serialized messages, `maxPendingRequests` applies request backpressure, and `maxChunkBytes` controls chunk size and validates inbound chunk allocation. Configurations that could require more than 10,000 chunks per message are rejected. Malformed, duplicate, incomplete, and oversized chunk sequences are rejected and cleaned up.

Message and response payloads must be JSON-compatible. Binary buffers, typed arrays, functions, symbols, BigInt values, cyclic objects, and custom class instances are rejected because JSON sizing cannot safely bound their structured-clone allocation.

## Cross-Origin Iframes

`WindowTransport` bootstraps a cross-origin iframe with `window.postMessage`, validates the exact origin and source window, and transfers a `MessagePort`. All Reworker messages then use that port.

Create the parent transport with the iframe's non-null `contentWindow` and an explicit origin:

```rescript
let transport = WindowTransport.Parent.make({
  targetOrigin: "https://frame.example.com",
  targetWindow: iframe->contentWindow,
  isTargetLoaded: () => true,
  addLoadListener: listener => iframe->addEventListener("load", listener),
  removeLoadListener: listener => iframe->removeEventListener("load", listener),
  requestTimeoutMs: 5000,
  maxMessageBytes: 32_000_000,
  maxPendingRequests: 100,
  maxChunkBytes: 1_000_000,
})

let runtime = Runtime.make(transport)

await WindowTransport.Parent.connect(transport)
let title = await Runtime.sendMessage(runtime, GetPageTitle)
```

Install the cooperating endpoint in the iframe before the parent connects:

```rescript
let transport = WindowTransport.Child.make({
  parentWindow: Webapi.Dom.window->Webapi.Dom.Window.parent,
  parentOrigin: "https://parent.example.com",
  requestTimeoutMs: 5000,
  maxMessageBytes: 32_000_000,
  maxPendingRequests: 100,
  maxChunkBytes: 1_000_000,
})

let runtime = Runtime.make(transport)

Runtime.OnMessage.addListener(runtime, handler)
WindowTransport.Child.listen(transport)->Result.getOrThrow
```

Both origins are mandatory and `"*"` is rejected. This example constructs the transport after the iframe's initial load; when constructing earlier, `isTargetLoaded` must return tracked initial-load state so that load is not mistaken for navigation. The parent transport reconnects with a new port after iframe navigation. Call `Runtime.close(runtime)` to reject pending requests, remove listeners, and permanently close that instance.

Subscribe to connection lifecycle changes. Each function returns an idempotent unsubscribe function:

```rescript
let removeOpen = Runtime.onOpen(runtime, () => Console.log("connected"))
let removeClose = Runtime.onClose(runtime, reason => Console.log(`closed: ${reason}`))
let removeReconnect = Runtime.onReconnect(runtime, () => Console.log("reconnected"))

// Deterministic component cleanup
removeOpen()
removeClose()
removeReconnect()
```

`onOpen` fires for the first successful connection. `onReconnect` fires after each later successful connection. `onClose` fires once when an open connection closes, including terminal `Runtime.close(runtime)`. Subscriptions do not replay past events.

Cancel requests with `AbortSignal`. Cancellation rejects locally, removes pending state, and aborts the matching remote handler:

```rescript
let controller = AbortController.make()
let request = Runtime.sendMessage(
  runtime,
  RunExpensiveTask(input),
  ~signal=controller->AbortController.signal,
)

controller->AbortController.abort
```

Message handlers receive `Some(signal)` for requests and `None` for casts. Long-running handlers should stop work when the signal aborts. Pre-aborted requests are never sent. Timeout, response, close, reconnect, and abort races settle each request once.

## Migration

This release replaces module functors with runtime and transport values:

- Replace `module Runtime = Runtime.Make(Bindings)` with a `Runtime.transport` value and `let runtime = Runtime.make(transport)`.
- Add lifecycle listeners, `isOpen`, `isCurrentSender`, `senderKey`, `close`, and mandatory resource limits to custom transports.
- Update handlers from `(message, sender)` to `(message, sender, signal)`.
- Replace window transport functors with `WindowTransport.Parent.make` or `WindowTransport.Child.make`.
- Start parent transports with `await WindowTransport.Parent.connect(transport)` and child transports with `WindowTransport.Child.listen(transport)`.
- Call `Runtime.close(runtime)` during teardown. Closed runtime values cannot reconnect or be reused.

Build a nice wrapper:
In your background.res:
```rescript
let getUser = userid => Runtime.sendMessage(runtime, GetUser(userid))
```
This allows callers to just do `let user = await Background.getUser("123")`
Simple. Clear.

## Features

- **Type safety**: GADTs ensure request/response type matching
- **Promise-based**: Native promises with async/await
- **Auto-chunking**: Transfers large messages transparently
- **Framework agnostic**: Works with browser applications and extension frameworks
- **Zero deps**: Pure ReScript library

## Requirements

- ReScript ^12.0.0
- A browser or worker environment with an ordered duplex transport

## License

MIT

## Thanks

[@diogomqbm](https://github.com/diogomqbm) for foundational work.
