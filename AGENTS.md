# ReWorker

`@bluehotdog/reworker` is a dependency-free ReScript library for type-safe,
chunked message passing in workers and browser extensions.

## Architecture

- `src/Types.res` defines the extensible `Types.message<_>` GADT. Each message
  constructor determines its response type.
- `src/Runtime.res` provides promise-based messaging through configurable
  runtime bindings.
- `src/TransportMessage.res`, `src/MessageChunker.res`, and
  `src/RequestHandler.res` implement transparent chunking and reassembly.
- `src/Response.res` represents immediate, deferred, and absent responses.
- `.resi` files define the public API and must stay synchronized with their
  implementations.

## Invariants

- Keep `TransportMessage` internal. Consumers send `Types.message<_>` values
  and must not handle transport messages or chunks.
- Preserve the request/response relationship encoded by the message GADT.
- Keep the library free of runtime dependencies.
- Prefer small, backward-compatible changes because this is a foundational
  library.
- Test both direct and chunked message paths when changing transport behavior.

## Development

- Use `make build` to compile.
- Use `make test` to run the test suite.
- Use `make format` to format ReScript files.
- Use `make help` to list all commands.

The project uses ReScript 12, ES modules, in-source compilation, and the
`.res.mjs` suffix. See `README.md` for consumer usage and the relevant `.resi`
file for the current API.
