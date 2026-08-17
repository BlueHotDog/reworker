# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Replace `Runtime.Make` and window transport functors with opaque, independently stateful transport and runtime values
- Require `Runtime.make(transport, ~limits, ~handler)`; constructing the runtime consumes and starts the transport
- Replace raw transport records with `Runtime.makeTransport`, whose startup receives runtime-owned `beginSession` capability and returns teardown
- Replace listener collections and separate lifecycle callbacks with one handler, `Runtime.status`, and `Runtime.onStatus`
- Pass `Runtime.Request(signal)` or `Runtime.Cast` to handlers and propagate request cancellation to the matching remote operation
- Configure window transports with explicit origins and a channel; parent transports also require `subscribeLoad` and `connectionTimeoutMs`
- Start parent and child window transports automatically when consumed instead of exposing `connect` or `listen`
- Keep runtime limits (`requestTimeoutMs`, `maxMessageBytes`, and `maxPendingRequests`) separate from transport `maxChunkBytes`
- Reserve enough message and chunk capacity for bounded protocol errors and one UTF-8 code point
- Make transports single-consumption and runtime-owned; `Runtime.close` performs terminal teardown
- Chunk oversized requests and casts using one logical ID, timeout, pending slot, and cancellation operation across all chunks
- Require ordered transport delivery and reject malformed, duplicate, out-of-order, incomplete, or oversized chunk sequences
- Send responses directly without response chunking, while bounding response payloads with `maxMessageBytes`
- Give each physical connection a runtime-owned session capability; beginning a replacement makes older session sinks stale and rejects their pending work
- Keep window handshake IDs private to `WindowTransport`; custom transports no longer generate, expose, or retain runtime session identifiers
- Validate JSON-compatible request, cast, and response payloads before dispatch
- Upgrade the development compiler from ReScript 12 beta to ReScript 12.3
- Support all stable ReScript 12 releases
- Restrict the supported package surface to consumer-facing modules
- Use ReScript 12's structured warning configuration and unified operators
- Make the test runner propagate failures to the calling process
- Run ReScript dead code analysis in local checks and CI
- Remove an unused handler-map module and obsolete runtime test mocks

### Added
- Initial implementation of type-safe Chrome extension message passing
- GADT-based message system with compile-time type safety
- Automatic request and cast chunking for large payloads
- Framework-agnostic value-level runtime API
- Support for WXT and raw Chrome extension APIs
- Comprehensive test suite with unit and integration tests
- Zero runtime dependencies architecture

### Features
- **Types.res**: Extensible GADT message type system
- **Runtime.res**: Generic value-level runtime with status, limits, teardown, and cancellation support
- **Response.res**: Type-safe response patterns (immediate, async, none)

### Documentation
- Comprehensive README with usage examples
- CLAUDE.md with detailed architecture documentation
- Agent specialization guide for different development areas

## [0.0.1] - 2025-01-XX

### Added
- Initial project setup with ReScript v12
- MIT license and proper copyright headers
- Basic package.json configuration
- Makefile-based task runner with standard targets
- .gitignore and .npmignore for ReScript library distribution

### Development Infrastructure
- ESModule output configuration
- In-source compilation setup
- Test runner with color-coded output
- Clean development workflow with watch mode

---

**Note**: This project is currently in development. The API may change before the first stable release.
