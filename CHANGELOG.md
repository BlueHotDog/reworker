# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial implementation of type-safe Chrome extension message passing
- GADT-based message system with compile-time type safety
- Automatic message chunking for large payloads
- Framework-agnostic Runtime.Make functor pattern
- Support for WXT and raw Chrome extension APIs
- Comprehensive test suite with unit and integration tests
- Zero runtime dependencies architecture

### Features
- **Types.res**: Extensible GADT message type system
- **Runtime.res**: Generic runtime wrapper with functor pattern
- **TransportMessage.res**: Internal chunking system (invisible to users)
- **MessageChunker.res**: Core chunking functionality with size limits
- **RequestHandler.res**: Automatic chunk reassembly
- **Response.res**: Type-safe response patterns (immediate, async, none)
- **Id.res**: UUID generation for chunk tracking

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