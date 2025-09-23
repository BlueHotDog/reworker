# Re-WebWorker Testing Guide

This document describes the testing infrastructure for the re-webworker library.

## Test Structure

Tests are organized next to their source files with the `__test` suffix:

```
src/
├── MessageChunker.res          # Core chunking logic
├── MessageChunker__test.res    # Unit tests for chunking
├── TransportMessage.res        # Transport message types
├── TransportMessage__test.res  # Unit tests for transport
├── Response.res                # Response type handling
├── Response__test.res          # Unit tests for responses
├── RequestHandler.res          # Chunk reassembly
├── RequestHandler__test.res    # Integration tests for handler
├── Runtime.res                 # Main runtime functor
├── Runtime__test.res           # Integration tests for runtime
└── TestRunner.res              # Test orchestration
```

## Running Tests

### All Tests
```bash
# Compile and run all tests
rescript && node src/TestRunner.res.mjs
```

### Individual Test Suites
```bash
# Run specific test suite
rescript && node src/MessageChunker__test.res.mjs
rescript && node src/TransportMessage__test.res.mjs
rescript && node src/Response__test.res.mjs
rescript && node src/RequestHandler__test.res.mjs
rescript && node src/Runtime__test.res.mjs
```

### Test Categories

#### Unit Tests Only
Tests individual modules in isolation:
- MessageChunker: Chunking logic, boundaries, encoding
- TransportMessage: Chunk creation, reassembly, metadata
- Response: Async flow, promise handling, type checking

#### Integration Tests Only
Tests module interactions:
- RequestHandler: Chunk collection, memory management, user handler integration
- Runtime: Response.t ↔ callback conversion, bindings integration

#### Smoke Test
Quick verification of basic functionality without full test suite.

## Test Focus Areas

### What Tests Cover
1. **Runtime Behavior**: Things the type system can't verify
2. **Boundary Conditions**: Edge cases, large messages, empty inputs
3. **Async Flow**: Promise resolution, timing, error handling
4. **Memory Management**: Chunk cleanup, concurrent messages
5. **Integration Points**: Module interactions, callback conversions

### What Tests Don't Cover
- Type safety (handled by ReScript compiler)
- Function signatures (enforced by type system)
- Basic module imports (compilation would fail)

## Test Types

### Unit Tests
- **MessageChunker**: Binary encoding integrity, chunk boundaries
- **TransportMessage**: Type constraints, metadata consistency
- **Response**: Promise behavior, pattern matching

### Integration Tests
- **RequestHandler**: Multi-chunk assembly, concurrent handling
- **Runtime**: Response.t conversion, error boundaries

### Mock Strategy
- **Chrome APIs**: Mocked for unit/integration testing
- **Bindings**: Test doubles with verification capabilities
- **Async Operations**: Controlled timing and error injection

## Test Patterns

### Message Testing
```rescript
// Create test messages of various sizes
let smallMessage = "test"
let largeMessage = createLargeString(50_000)

// Test chunking decisions
let shouldChunk = message->MessageChunker.shouldBeChunked
```

### Response Testing
```rescript
// Test all response types
let immediate = Response.now("value")
let async = Response.later(Promise.resolve("value"))
let none = Response.none

// Verify behavior
assert(Response.isImmediate(immediate))
assert(Response.isAsync(async))
assert(!Response.hasResponse(none))
```

### Async Testing
```rescript
// Test promise resolution
let testAsync = async () => {
  let promise = createTestPromise("result", 50)
  let response = Response.later(promise)
  let result = await extractPromise(response)
  assert(result === "result")
}
```

## Error Scenarios

Tests cover various error conditions:
1. **Malformed chunks**: Invalid metadata, missing chunks
2. **Promise rejections**: Async handler failures
3. **User handler errors**: Exceptions in message handlers
4. **Memory conditions**: Large message handling
5. **Concurrent access**: Multiple messages with same ID

## Performance Considerations

While not full performance tests, the suite includes:
- Large message handling (50MB+)
- Concurrent message scenarios
- Memory cleanup verification
- Chunking overhead awareness

## Best Practices

1. **Test Near Code**: Tests sit next to source files
2. **Focus on Runtime**: Test what types can't verify
3. **Mock Externals**: Use test doubles for Chrome APIs
4. **Verify Cleanup**: Check memory management
5. **Test Boundaries**: Edge cases and error conditions

## Adding New Tests

When adding new functionality:

1. Create `ModuleName__test.res` next to `ModuleName.res`
2. Focus on runtime behavior, not type safety
3. Test error conditions and edge cases
4. Add to `TestRunner.res` for full suite execution
5. Document any new test patterns or mocks

## Continuous Integration

Tests are designed to run in Node.js environment without browser dependencies. Chrome API functionality is mocked for testing, with real browser testing handled separately in end-to-end scenarios.