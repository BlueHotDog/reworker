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

let testPreparedJson = () => {
  let prepared = MessageChunker.prepareJson({"message": "hello"})
  prepared.encoded->Option.isSome && prepared.byteLength === 19
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

// Run all tests
let runTests = () => {
  let tests = [
    ("JSON preparation", testPreparedJson),
    ("Chunk split and reassemble", testChunkSplitAndReassemble),
    ("Unicode handling", testUnicodeHandling),
  ]

  TestUtils.runSyncTests("MessageChunker Unit Tests", tests)
}

// Export for running
let main = runTests
