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
  let prepared =
    MessageChunker.prepareJsonWithin({"message": "hello"}, ~maxBytes=19)->Option.getOrThrow
  let withinLimit = MessageChunker.prepareJsonWithin({"message": "hello"}, ~maxBytes=19)
  let overLimit = MessageChunker.prepareJsonWithin({"message": "hello"}, ~maxBytes=18)
  prepared.encoded->Option.isSome &&
  prepared.encoded->Option.getOrThrow->TypedArray.byteLength === 19 &&
  withinLimit->Option.isSome &&
  overLimit->Option.isNone
}

let testCanonicalJson = () => {
  try {
    let prepared =
      MessageChunker.prepareJsonWithin(
        {"value": Float.Constants.nan},
        ~maxBytes=100,
      )->Option.getOrThrow
    prepared.value->JSON.stringifyAny === Some(`{"value":null}`)
  } catch {
  | _ => false
  }
}

let testActualChunkLimit = () => {
  try {
    let original = createLargeString(10_000)
    let chunks =
      original
      ->MessageChunker.prepareJsonWithin(~maxBytes=20_000)
      ->Option.getOrThrow
      ->MessageChunker.chunkPrepared(~size=4)
      ->Option.getOrThrow
    chunks->Array.length < MessageChunker.maxChunksPerMessage &&
      chunks->Array.join("")->JSON.parseOrThrow === original->Obj.magic
  } catch {
  | _ => false
  }
}

let testRejectsUnsafeChunkSize = () => {
  try {
    "four"
    ->MessageChunker.prepareJsonWithin(~maxBytes=100)
    ->Option.getOrThrow
    ->MessageChunker.chunkPrepared(~size=3)
    ->ignore
    false
  } catch {
  | _ => true
  }
}

let testPreservesBomAtChunkBoundary = () => {
  let original = "aaa\u{FEFF}a"
  let chunks =
    original
    ->MessageChunker.prepareJsonWithin(~maxBytes=100)
    ->Option.getOrThrow
    ->MessageChunker.chunkPrepared(~size=4)
    ->Option.getOrThrow
  chunks->Array.join("")->JSON.parseOrThrow === original->Obj.magic
}

// Test: Chunk splitting and reassembly
let testChunkSplitAndReassemble = () => {
  let chunkSize = 1000
  let originalMessage = createLargeString(chunkSize * 2 + 500)

  try {
    let chunks =
      originalMessage
      ->MessageChunker.prepareJsonWithin(~maxBytes=10_000)
      ->Option.getOrThrow
      ->MessageChunker.chunkPrepared(~size=chunkSize)
      ->Option.getOrThrow

    // Verify we got multiple chunks
    if chunks->Array.length < 2 {
      Console.error("FAIL: Large message didn't split into multiple chunks")
      false
    } else {
      // Reassemble
      let reassembled: string = chunks->Array.join("")->JSON.parseOrThrow->Obj.magic

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
    let chunks =
      repeated
      ->MessageChunker.prepareJsonWithin(~maxBytes=100_000)
      ->Option.getOrThrow
      ->MessageChunker.chunkPrepared(~size=1000)
      ->Option.getOrThrow
    let reassembled: string = chunks->Array.join("")->JSON.parseOrThrow->Obj.magic

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
    ("JSON canonicalization", testCanonicalJson),
    ("Actual chunk limit", testActualChunkLimit),
    ("Unsafe chunk size", testRejectsUnsafeChunkSize),
    ("BOM at chunk boundary", testPreservesBomAtChunkBoundary),
    ("Chunk split and reassemble", testChunkSplitAndReassemble),
    ("Unicode handling", testUnicodeHandling),
  ]

  TestUtils.runSyncTests("MessageChunker Unit Tests", tests)
}

// Export for running
let main = runTests
