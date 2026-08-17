# Issue 23 Resilient Architecture

## Objective

Replace duplicated runtime and window lifecycle state with explicit ownership and
runtime-issued session capabilities. A logical request has one identifier,
timeout, abort subscription, and inbound operation from first frame through
final response.

## Contracts

- Runtime exclusively consumes and closes one transport.
- Fallible transport startup releases acquired resources before throwing.
- Transport calls `beginSession()` once for each physical connection, then
  reports through returned `opened`, `message`, and `disconnected` capabilities.
- Runtime owns session identity. Beginning replacement session clears prior
  session work and makes all older session capabilities stale automatically.
- Window transport owns bootstrap, readiness, load observation, ports, and
  connection replacement.
- Window handshake IDs are private protocol details used only to correlate its
  own bootstrap and port messages. They are not runtime session identity and do
  not cross public transport boundary.
- Runtime owns protocol encoding, correlation, cancellation, assembly, limits,
  handlers, and public lifecycle status.
- `Runtime.make(transport, ~limits, ~handler)` consumes and starts the transport.
  A transport value cannot be inspected, started again, or shared by runtimes.
- Terminal close commits before cleanup or callbacks and has no outgoing state
  transition.
- User callbacks run only after a transition commits. One callback failure does
  not prevent cleanup or later callbacks.
- Direct and chunked requests use one logical request ID, one pending slot, one
  local timeout deadline, and one cancellation operation. Chunk count does not
  multiply request state.
- Cancellation removes one inbound operation, then either drops its assembly or
  aborts its running handler.
- Ordered transports receive chunks in order. Out-of-order or duplicate chunks
  are protocol errors; no sorting or per-chunk acknowledgement is required.
- Payloads are JSON-compatible. Validation, normalization, measurement, and
  chunk preparation reuse one serialized representation where possible.
- Responses are direct protocol messages, not chunk sequences. Both endpoints
  validate them against `maxMessageBytes`; an oversized successful response is
  replaced by a bounded failure.

## Public API Direction

- `Runtime.transport` is opaque and created through a constructor for custom
  transports.
- `Runtime.makeTransport` startup receives `~beginSession`; transport does not
  provide lifecycle IDs or construct runtime session tokens.
- Runtime limits are passed to `Runtime.make`, not stored in transport records.
- Runtime limits are `requestTimeoutMs`, `maxMessageBytes`, and
  `maxPendingRequests`. Transport `maxChunkBytes` is separate and controls
  request and cast chunk-body size plus inbound chunk validation.
- Transport registration returns one idempotent teardown function.
- `Runtime.status` and `Runtime.onStatus` replace inferred open, close, reconnect,
  and context-validity APIs.
- One handler is supplied explicitly instead of exposing collection-shaped
  listener APIs.
- The handler context is `Runtime.Request(signal)` for requests and
  `Runtime.Cast` for casts. Request handlers can subscribe with
  `AbortSignal.onAbort`; casts have no response or cancellation signal.
- `WindowTransport.Parent.make` and `Child.make` return opaque runtime transports
  that start when consumed by `Runtime.make`; callers cannot post or close them.
- Parent and child configs use the same non-empty `channel` to isolate logical
  endpoints sharing a window. Parent config also supplies `subscribeLoad` and
  `connectionTimeoutMs`; child config waits for matching parent bootstrap.
- Window transports start automatically. There is no public `connect`, `listen`,
  or raw window-transport lifecycle API.

## Testing Strategy

- Unit tests cover protocol transitions, single-ID chunking, cancellation races,
  stale session capabilities, bounded operation state, and terminal close.
- Window transport tests cover initial load, stale readiness timeout, reentrant
  close, endpoint identity, exact origin/source validation, and listener cleanup.
- Browser tests cover two concurrent frames, navigation, cancellation, and close.
- Commands: `make build`, `make test`, `make test-browser`, `make analyze`, and
  `npx rescript format --check`.

## Boundaries

- Always preserve the message GADT request/response relationship.
- Always validate untrusted protocol and window envelopes before typed dispatch.
- Never add runtime dependencies.
- Never retain compatibility shims for the pre-adoption API.
- Never edit generated `.res.mjs` files.

## Success Criteria

- Runtime and window transport each have one authoritative state representation.
- Closing during any lifecycle callback cannot create or reopen a connection.
- Stale readiness and timeout callbacks cannot replace current window state.
- Message, open, or disconnect callbacks on stale sessions cannot affect runtime.
- Chunk count does not multiply pending requests, timers, or abort listeners.
- One bounded inbound map owns assembling and executing requests.
- Public transport API does not expose extension state, raw listener pairs,
  sender-key functions, lifecycle identifiers, or mutable window transport
  records.
- Full unit, browser, build, formatting, and analysis checks pass.
