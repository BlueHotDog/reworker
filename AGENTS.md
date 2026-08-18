# ReWorker

`@bluehotdog/reworker` is a dependency-free ReScript library for type-safe,
chunked message passing in workers and Manifest V3 browser extensions.

## Architecture

- `src/Types.res` defines the extensible `Types.message<_>` GADT. Each message
  constructor determines its response type.
- `src/Runtime.res` owns protocol framing, lifecycle state, request handling,
  cancellation, and transparent chunk reassembly.
- `src/MessageChunker.res` validates and prepares JSON payloads once, then
  splits their encoded bytes at safe UTF-8 boundaries when needed.
- `src/Response.res` represents immediate, deferred, and absent responses.
- `src/Channel.res` and `src/ChannelTypes.res` provide persistent port channels
  for background and tab connections.
- Tests are colocated in `src/*__test.res` and registered in
  `src/TestRunner.res`.

## Invariants

- Keep transport details out of the consumer-facing runtime API. Consumers send
  `Types.message<_>` values and must not handle chunks.
- Preserve the request/response relationship encoded by the message GADT.
- Keep the library free of runtime dependencies.
- Treat `.resi` files as API boundaries and update them with their
  implementations when a public signature changes.
- Test both direct and chunked message paths when changing transport behavior.

## Workflow

- Install dependencies with `npm ci`.
- Compile with `make build`; warnings are treated as errors.
- Run the complete test suite with `make test`.
- Run dead code analysis with `make analyze`.
- Format ReScript sources with `make format` and check formatting with
  `npx rescript format --check`.
- Edit `.res` and `.resi` sources, not generated `.res.mjs` files or `lib/`
  artifacts.
- Add new test modules to `src/TestRunner.res` so `make test` executes them.

The project requires Node.js 20.11 or newer and ReScript 12. It emits ES modules
in source with the `.res.mjs` suffix. See `README.md` for consumer usage.
