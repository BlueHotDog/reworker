# Re-WebWorker

Type-safe message passing for Chrome extensions with automatic chunking. Zero dependencies.

## Install

```bash
npm install @bluehotdog/re-webworker
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
Runtime.sendMessage(GetUser("123"), user => Console.log(user))
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

## Features

- **Type safety**: GADTs ensure request/response type matching
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
