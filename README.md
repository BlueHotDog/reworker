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

- ReScript ^12.0.0-beta.12
- Manifest V3 extensions only

## License

MIT

## Thanks

[@diogomqbm](https://github.com/diogomqbm) for foundational work.
