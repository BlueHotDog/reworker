/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Unit tests for MessageChunker module
// Testing chunking logic, boundaries, and binary encoding

// Test helper to create large strings
let createLargeString = size => {
  "a"->String.repeat(size)
}

// Test: Small messages should not be chunked
let testSmallMessageNotChunked = () => {
  let smallMessage = "Hello, world!"
  let shouldChunk = smallMessage->MessageChunker.shouldBeChunked

  if shouldChunk {
    Console.error("FAIL: Small message incorrectly marked for chunking")
    false
  } else {
    Console.log("PASS: Small message correctly not chunked")
    true
  }
}

// Test: Large messages should be chunked
let testLargeMessageChunked = () => {
  let largeMessage = createLargeString(MessageChunker.defaultChunkSize + 1000)
  let shouldChunk = largeMessage->MessageChunker.shouldBeChunked

  if shouldChunk {
    Console.log("PASS: Large message correctly marked for chunking")
    true
  } else {
    Console.error("FAIL: Large message incorrectly not marked for chunking")
    false
  }
}

// Test: Messages exactly at threshold
let testThresholdBoundary = () => {
  // JSON serialization adds two quote bytes around these ASCII strings.
  let exactThreshold = createLargeString(MessageChunker.defaultChunkSize - 2)
  let justOver = createLargeString(MessageChunker.defaultChunkSize - 1)
  let justUnder = createLargeString(MessageChunker.defaultChunkSize - 3)

  let exactShouldChunk = exactThreshold->MessageChunker.shouldBeChunked
  let overShouldChunk = justOver->MessageChunker.shouldBeChunked
  let underShouldChunk = justUnder->MessageChunker.shouldBeChunked

  let results = [
    (!underShouldChunk, "Just under threshold should not chunk"),
    (overShouldChunk, "Just over threshold should chunk"),
    (!exactShouldChunk, "Exact threshold should not chunk"),
  ]

  let allPassed = results->Array.every(((passed, message)) => {
    if passed {
      Console.log(`PASS: ${message}`)
    } else {
      Console.error(`FAIL: ${message}`)
    }
    passed
  })

  allPassed
}

// Test: Chunk splitting and reassembly
let testChunkSplitAndReassemble = () => {
  let originalMessage = createLargeString(MessageChunker.defaultChunkSize * 2 + 500)

  try {
    // Split into chunks
    let chunks =
      originalMessage->MessageChunker.splitIntoChunks(~size=MessageChunker.defaultChunkSize, ())

    // Verify we got multiple chunks
    if chunks->Array.length < 2 {
      Console.error("FAIL: Large message didn't split into multiple chunks")
      false
    } else {
      // Decode chunks back to strings
      let decodedChunks = chunks->Array.map(MessageChunker.decodeBinary)

      // Reassemble
      let reassembled = decodedChunks->Array.join("")

      if reassembled === originalMessage {
        Console.log(
          `PASS: Message split into ${chunks
            ->Array.length
            ->Int.toString} chunks and reassembled correctly`,
        )
        true
      } else {
        Console.error("FAIL: Reassembled message doesn't match original")
        Console.log(`Original length: ${originalMessage->String.length->Int.toString}`)
        Console.log(`Reassembled length: ${reassembled->String.length->Int.toString}`)
        false
      }
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during chunking:", error)
    false
  }
}

// Test: Unicode handling
let testUnicodeHandling = () => {
  let unicodeMessage = "Hello 世界 🌍 مرحبا עולם Здравствуй"
  let repeated = Array.fromInitializer(~length=1000, _ => unicodeMessage)->Array.join(" ")

  try {
    let chunks = repeated->MessageChunker.splitIntoChunks(~size=1000, ())
    let decodedChunks = chunks->Array.map(MessageChunker.decodeBinary)
    let reassembled = decodedChunks->Array.join("")

    if reassembled === repeated {
      Console.log("PASS: Unicode characters handled correctly in chunking")
      true
    } else {
      Console.error("FAIL: Unicode characters corrupted during chunking")
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during unicode chunking:", error)
    false
  }
}

// Test: Empty message handling
let testEmptyMessage = () => {
  let emptyMessage = ""
  let shouldChunk = emptyMessage->MessageChunker.shouldBeChunked

  if shouldChunk {
    Console.error("FAIL: Empty message incorrectly marked for chunking")
    false
  } else {
    Console.log("PASS: Empty message correctly not chunked")
    true
  }
}

// Run all tests
let runTests = () => {
  let tests = [
    ("Small message not chunked", testSmallMessageNotChunked),
    ("Large message chunked", testLargeMessageChunked),
    ("Threshold boundary", testThresholdBoundary),
    ("Chunk split and reassemble", testChunkSplitAndReassemble),
    ("Unicode handling", testUnicodeHandling),
    ("Empty message", testEmptyMessage),
  ]

  TestUtils.runSyncTests("MessageChunker Unit Tests", tests)
}

// Export for running
let main = runTests
