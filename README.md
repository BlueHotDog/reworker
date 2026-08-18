# ReWorker

Type-safe message passing for browser windows, workers, and extensions with
automatic request and cast chunking. Zero runtime dependencies.

## Install

```bash
npm install @bluehotdog/reworker
```

## Usage

Define messages with an extensible GADT. Each constructor fixes its response
type:

```rescript
type user = {id: string, name: string}

type Types.message<_> +=
  | GetUser(string): Types.message<option<user>>
  | SaveData(string): Types.message<unit>
  | RunExpensiveTask(string): Types.message<string>
```

Adapt your connection once. `Runtime.makeTransport` covers connections that open
immediately and do not reconnect themselves:

```rescript
let transport = Runtime.makeTransport(
  ~maxChunkBytes=1_000_000,
  ~postMessage=RawConnection.postMessage,
  ~subscribe=(~onMessage, ~onDisconnect) =>
    RawConnection.subscribe(~onMessage, ~onDisconnect),
)
```

Define limits and one application handler:

```rescript
let limits: Runtime.limits = {
  requestTimeoutMs: 5000,
  maxMessageBytes: 32_000_000,
  maxPendingRequests: 100,
}

let handler:
  type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
  (message, _sender, context) => {
    switch message {
    | GetUser(id) => Response.now(Users.get(id))
    | SaveData(data) => {
        Storage.save(data)->ignore
        Response.none
      }
    | RunExpensiveTask(input) =>
      switch context {
      | Runtime.Request(signal) => {
          AbortSignal.onAbort(signal, () => Jobs.cancel(input))->ignore
          Response.later(Jobs.run(input))
        }
      | Runtime.Cast => Response.none
      }
    | _ => Response.none
    }
  }
```

Request handlers receive `Runtime.Request(signal)`. Cast handlers receive
`Runtime.Cast`; casts have no response or cancellation signal.
`AbortSignal.onAbort(signal, callback)` returns an idempotent unsubscribe
function. Long-running request handlers should stop work after abort.

Create the runtime, then expose small domain functions. Callers do not need to
know about runtime or transport details:

```rescript
let runtime = Runtime.make(transport, ~limits, ~handler)

let getUser = userId => Runtime.sendMessage(runtime, GetUser(userId))
let saveData = data => Runtime.cast(runtime, SaveData(data))
```

Call these functions from application code:

```rescript
let user = await Background.getUser("123")
Background.saveData("saved without a response")
```

Cancel an outgoing request with `AbortController`:

```rescript
let controller = AbortController.make()
let _request = Runtime.sendMessage(
  runtime,
  RunExpensiveTask("report"),
  ~signal=controller->AbortController.signal,
)

controller->AbortController.abort
```

A pre-aborted request is not sent. An in-flight abort rejects the local promise
and cancels the matching remote assembly or handler. Timeout and abort races
settle the request once.

## Runtime Status

Read current status with `Runtime.status`. Subscribe to later transitions with
`Runtime.onStatus`; it returns an idempotent unsubscribe function.

Use `Runtime.whenOpen` when startup is asynchronous. It resolves immediately for
an open runtime, waits across connection attempts, and rejects if runtime closes:

```rescript
await Runtime.whenOpen(runtime)
let user = await Runtime.sendMessage(runtime, GetUser("123"))
```

```rescript
let _initialStatus = Runtime.status(runtime)

let unsubscribe = Runtime.onStatus(runtime, status => {
  switch status {
  | Runtime.Connecting => Console.log("connecting")
  | Runtime.Open => Console.log("connected")
  | Runtime.Disconnected(reason) => Console.log(`disconnected: ${reason}`)
  | Runtime.Closed(reason) => Console.log(`closed: ${reason}`)
  }
})

unsubscribe()
Runtime.close(runtime)
```

Subscriptions do not replay current status, so use `Runtime.status` for an
initial snapshot. `Runtime.close` is terminal and idempotent. It rejects pending
requests, aborts inbound handlers, runs transport teardown, and publishes
`Runtime.Closed("Runtime closed")`.

## Transport Ownership

A `Runtime.transport` is opaque and single-consumption. `Runtime.make` takes
ownership, starts it automatically, and retains its teardown. Reusing one
transport in another runtime throws, including when first startup failed.

Applications do not call `connect`, `listen`, `postMessage`, or raw transport
lifecycle methods. Use `Runtime.status`, `Runtime.onStatus`, and `Runtime.close`
after ownership transfers to runtime.

Transport must provide ordered duplex delivery. For each physical connection,
transport begins a runtime session and reports open, message, and disconnect
through that session's capability sink. Beginning replacement session makes all
callbacks on previous sink stale automatically and rejects its pending work.

## Limits And Chunking

Runtime and transport limits serve different purposes:

- `requestTimeoutMs` is one deadline covering outbound requests and inbound
  request assembly plus handler execution.
- `maxMessageBytes` bounds complete requests, casts, and responses.
- `maxPendingRequests` bounds outgoing pending requests and inbound operations.
- `maxChunkBytes` belongs to transport and controls request/cast chunk-body size
  and inbound chunk validation. Protocol metadata adds frame overhead.

`maxMessageBytes` must be at least 64 bytes so runtime-generated protocol errors
remain bounded. `maxChunkBytes` must be at least 4 bytes so one UTF-8 code point
always fits.

Large requests and casts are split transparently. One logical request keeps one
ID, pending slot, timeout deadline, and cancellation operation across all its
chunks. Chunk count does not create extra pending requests, timers, or abort
subscriptions. Chunks must arrive in exact order; malformed, duplicate,
out-of-order, incomplete, or oversized sequences are rejected and cleaned up.

Responses are sent directly and are not chunked. Successful responses and
remote errors are bounded by `maxMessageBytes`; oversized or unserializable
responses become bounded failures. Transport must therefore carry direct
response protocol messages up to configured runtime bound.

Payloads use standard JSON serialization semantics. Each outbound payload is
serialized once during preparation. Runtime uses the parsed result for direct
delivery and chunks the same encoded bytes when needed. Normal JSON conversions
therefore apply, such as non-finite numbers becoming `null` and undefined object
fields being omitted.

## Cross-Origin Iframes

`WindowTransport` bootstraps exact-origin communication with
`window.postMessage`, validates source window, and transfers `MessagePort`.
Subsequent protocol traffic uses that ordered port.

Window handshake IDs are private implementation details for bootstrap and port
correlation. They are not exposed as transport lifecycle identity; Runtime owns
session identity through `beginSession` capabilities.

Parent and child must use same non-empty `channel`. Channel isolates independent
runtimes that share same parent and child windows. Concurrent endpoint pairs
must use distinct channel names.

Create parent transport with iframe target, load subscription, connection
readiness timeout, and transport chunk size:

```rescript
let parentTransport = WindowTransport.Parent.make({
  targetWindow: iframe->contentWindow,
  targetOrigin: "https://frame.example.com",
  channel: "account-panel",
  subscribeLoad: listener => {
    iframe->addEventListener("load", listener)
    () => iframe->removeEventListener("load", listener)
  },
  connectionTimeoutMs: 5000,
  maxChunkBytes: 1_000_000,
})

let parentRuntime = Runtime.make(parentTransport, ~limits, ~handler)
```

Create matching child transport in iframe:

```rescript
let childTransport = WindowTransport.Child.make({
  parentWindow: Webapi.Dom.window->Webapi.Dom.Window.parent,
  parentOrigin: "https://parent.example.com",
  channel: "account-panel",
  maxChunkBytes: 1_000_000,
})

let childRuntime = Runtime.make(childTransport, ~limits, ~handler)
```

`Runtime.make` starts both endpoints automatically. Parent begins connection
bootstrap and child begins listening for matching bootstrap; there is no
`WindowTransport.Parent.connect` or `WindowTransport.Child.listen`. Await
`Runtime.whenOpen` before sending. Parent reconnects after subscribed iframe load,
using `connectionTimeoutMs` to bound readiness wait. Wildcard or empty origins
are rejected.

`subscribeLoad` must register callback and return its teardown. It should report
future iframe loads, including navigation. Runtime close removes this listener
and closes active port. If registration throws before returning teardown,
`subscribeLoad` must remove any listener it already installed.

## Custom Transports

Use `Runtime.makeTransport` for a single ordered duplex connection:

```rescript
let transport = Runtime.makeTransport(
  ~maxChunkBytes=1_000_000,
  ~postMessage=RawConnection.postMessage,
  ~subscribe=(~onMessage, ~onDisconnect) =>
    RawConnection.subscribe(~onMessage, ~onDisconnect),
)

let runtime = Runtime.make(transport, ~limits, ~handler)
```

`postMessage` returns `Ok()` or `Error(message)`, including structured-clone
failure. `subscribe` installs message and disconnect callbacks and returns
teardown. Runtime opens this transport immediately and calls teardown once when
closed. If `subscribe` throws after acquiring resources, it must release them
before throwing because no teardown was returned.

### Dynamic Transports

Only transport implementations that manage physical reconnects need
`Runtime.makeDynamicTransport`. Its `start` callback receives `beginSession`.
Call `beginSession()` once per physical connection, then report lifecycle through
returned `opened`, `message`, and `disconnected` functions. A new session makes
older callbacks inert.

`beginSession()` publishes `Runtime.Connecting` synchronously. Recheck transport
state before installing resources because status listeners can close runtime
during this callback. `start` must return one teardown that releases current
connection and listener resources without retaining old session disposers. If
`start` throws after acquiring resources, it must release them before throwing.

Custom transport must preserve callback and chunk order. Runtime does not sort
chunks or acknowledge individual chunks.

## Migration

- Replace `module Runtime = Runtime.Make(Bindings)` with transport value and
  `Runtime.make(transport, ~limits, ~handler)`.
- Replace simple transport records with `Runtime.makeTransport` and a `subscribe`
  callback. Use `Runtime.makeDynamicTransport` only for transport-managed reconnects.
- Move request limits to `Runtime.make`; keep `maxChunkBytes` in transport.
- Update handlers to receive `Runtime.Request(signal) | Runtime.Cast` context.
- Replace handler listener registration with mandatory `~handler` argument.
- Replace lifecycle callbacks with `Runtime.status` and `Runtime.onStatus`.
- Replace readiness promises with `Runtime.whenOpen(runtime)`.
- Replace window functors with `WindowTransport.Parent.make` or
  `WindowTransport.Child.make`, including matching `channel` values.
- Remove explicit `connect` and `listen`; startup occurs in `Runtime.make`.
- Change cast-only constructors to `Types.message<unit>`; use `sendMessage` when a
  response is required.
- Replace `isContextValid()` with `Runtime.status(runtime) === Runtime.Open`.
- Call `Runtime.close(runtime)` for terminal teardown. Do not reuse transport.

## Features

- **Type safety**: GADTs preserve request and response relationship
- **Promise API**: Native promises with async/await and cancellation
- **Transparent chunking**: Large requests and casts use bounded ordered chunks
- **Resilient lifecycle**: Session isolation, reconnect status, and teardown
- **Framework agnostic**: Browser applications and extension frameworks
- **Zero dependencies**: No runtime dependencies

## Requirements

- ReScript ^12.0.0
- Browser or worker environment with ordered duplex transport

## License

MIT

## Thanks

[@diogomqbm](https://github.com/diogomqbm) for foundational work.
