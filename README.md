# ReWorker

Type-safe message passing for Chrome extensions with automatic chunking. Zero dependencies.

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

Send messages:
```rescript
module Runtime = Runtime.Make(WxtRuntime)

// Promise-based API
Runtime.sendMessage(GetUser("123"))->Promise.then(user => Console.log(user))

// With async/await
let user = await Runtime.sendMessage(GetUser("123"))
Console.log(user)

// Fire-and-forget
Runtime.cast(SaveData(userData))
```

Handle messages:
```rescript
let handler = (msg, _sender) => {
  switch msg {
  | GetUser(id) => Response.now(Database.getUser(id))
  | SaveData(data) => Response.now(Database.save(data))
  | _ => Response.none
  }
}
Runtime.OnMessage.addListener(handler)
```

Bindings passed to `Runtime.Make` provide an ordered duplex transport. Reworker owns request correlation, timeouts, remote errors, casts, and chunking:

```rescript
module type MyBindings = {
  type sender
  let requestTimeoutMs: int
  let postMessage: 'a => result<unit, string>
  module OnMessage: {
    let addListener: (('a, sender) => unit) => unit
    let removeListener: (('a, sender) => unit) => unit
  }
  module OnClose: {
    let addListener: (string => unit) => unit
  }
  let isOpen: unit => bool
  let close: unit => unit
}
```

`postMessage` must return `Error` when structured clone fails. `OnClose` must fire when the remote endpoint becomes unavailable so pending requests reject immediately.

## Cross-Origin Iframes

`WindowTransport` bootstraps a cross-origin iframe with `window.postMessage`, validates the exact origin and source window, and transfers a `MessagePort`. All Reworker messages then use that port.

Create the parent binding with the iframe's non-null `contentWindow` and an explicit origin:

```rescript
module FrameBindings = WindowTransport.Parent.Make({
  type targetWindow = Webapi.Dom.Window.t
  type loadEvent = Webapi.Dom.Event.t
  let targetOrigin = "https://frame.example.com"
  let targetWindow = () => iframe->contentWindow
  let addLoadListener = listener => iframe->addEventListener("load", listener)
  let removeLoadListener = listener => iframe->removeEventListener("load", listener)
  let requestTimeoutMs = 5000
})

module FrameRuntime = Runtime.Make(FrameBindings)

await FrameBindings.connect()
let title = await FrameRuntime.sendMessage(GetPageTitle)
```

Install the cooperating endpoint in the iframe before the parent connects:

```rescript
module ParentBindings = WindowTransport.Child.Make({
  type parentWindow = Webapi.Dom.Window.t
  let parentWindow = Webapi.Dom.window->Webapi.Dom.Window.parent
  let parentOrigin = "https://parent.example.com"
  let requestTimeoutMs = 5000
})

module ParentRuntime = Runtime.Make(ParentBindings)

ParentRuntime.OnMessage.addListener(handler)
ParentBindings.listen()->Result.getOrThrow
```

Both origins are mandatory and `"*"` is rejected. The parent binding reconnects with a new port after iframe navigation. Call `Runtime.close()` to reject pending requests and tear down the endpoint.

Build a nice wrapper:
In your background.res:
```rescript
let getUser = (userid)=> Runtime.sendMessage(GetUser(userid))
```
This allows callers to just do `let user = await Background.getUser("123")`
Simple. Clear.

## Features

- **Type safety**: GADTs ensure request/response type matching
- **Promise-based**: Native Manifest V3 promise support with async/await
- **Auto-chunking**: Handles Chrome's 64MB message limits transparently
- **Framework agnostic**: Works with any Chrome extension framework
- **Zero deps**: Pure ReScript library

## Requirements

- ReScript ^12.0.0
- Manifest V3 extensions only

## License

MIT

## Thanks

[@diogomqbm](https://github.com/diogomqbm) for foundational work.
