# Issue 23 Simplification

## Objective

Preserve issue 23 behavior while removing accidental complexity from runtime
dispatch, chunk assembly, and lifecycle ownership.

## Architecture

- Register one protocol listener per runtime.
- Decode or reassemble each inbound transport message once.
- Dispatch completed user messages to application handlers in runtime order.
- Keep first-response-wins semantics and abort losing deferred handlers.
- Keep chunk assembly in one request-path implementation.
- Keep window connection lifecycle inside `WindowTransport`.

## Boundaries

- Preserve public `.resi` signatures and documented error behavior.
- Preserve request typing, casts, cancellation, limits, generations, and teardown.
- Do not add dependencies or compatibility shims.
- Do not weaken validation or resource accounting.

## Tasks

1. Replace per-handler transport listeners with one runtime dispatcher.
2. Remove duplicate-delivery and completed-assembly bookkeeping.
3. Remove response chunking added during hardening; retain bounded responses.
4. Simplify tests and documentation only where behavior remains explicit.

## Verification

- `make test`
- `make test-browser`
- `make analyze`
- `npx rescript format --check`
- `git diff --check`

## Success Criteria

- One transport message listener handles runtime protocol traffic.
- No request/cast delivery maps or completed chunk replay cache remain.
- Response size remains bounded without a second assembly protocol.
- Runtime and request-handler code shrink materially.
- Existing tests pass without relaxing assertions.
