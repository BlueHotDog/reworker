@@warning("-4")
/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Unit tests for TransportMessage module
// Testing chunk creation, reassembly, and type constraints

// Test helper for creating test messages
let createTestMessage = content => {
  // Simple message structure for testing
  {
    "type": "test",
    "content": content,
  }
}

// Test: Small message creates UserMessage variant
let testSmallMessageCreatesUserMessage = () => {
  let smallMessage = createTestMessage("small")

  try {
    let chunks = TransportMessage.createChunks(smallMessage)

    if chunks->Array.length === 1 {
      switch chunks[0] {
      | Some(TransportMessage.UserMessage(_)) =>
        Console.log("PASS: Small message creates UserMessage variant")
        true
      | Some(_) =>
        Console.error("FAIL: Small message created wrong variant")
        false
      | None =>
        Console.error("FAIL: No chunks created for small message")
        false
      }
    } else {
      Console.error(
        `FAIL: Small message created ${chunks->Array.length->Int.toString} chunks, expected 1`,
      )
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during small message chunking:", error)
    false
  }
}

// Test: Large message creates chunk variants
let testLargeMessageCreatesChunks = () => {
  // Create a large message
  let largeContent =
    Array.fromInitializer(~length=1000, i => `item${i->Int.toString}`)->Array.join(" ")
  let largeMessage = createTestMessage(largeContent)

  try {
    let chunks = TransportMessage.createChunks(largeMessage, ~size=1000)

    if chunks->Array.length > 1 {
      // Check first chunk is IntermediateChunk
      let firstChunkOk = switch chunks[0] {
      | Some(TransportMessage.IntermediateChunk(_)) => true
      | _ => false
      }

      // Check last chunk is FinalChunk
      let lastChunkOk = switch chunks[chunks->Array.length - 1] {
      | Some(TransportMessage.FinalChunk(_)) => true
      | _ => false
      }

      // Check middle chunks are IntermediateChunk
      let middleChunksOk =
        chunks
        ->Array.slice(~start=1, ~end=chunks->Array.length - 1)
        ->Array.every(chunk => {
          switch chunk {
          | TransportMessage.IntermediateChunk(_) => true
          | _ => false
          }
        })

      if firstChunkOk && lastChunkOk && middleChunksOk {
        Console.log(
          `PASS: Large message creates ${chunks
            ->Array.length
            ->Int.toString} chunks with correct variants`,
        )
        true
      } else {
        Console.error("FAIL: Chunk variants are incorrect")
        Console.log(`First chunk ok: ${firstChunkOk ? "yes" : "no"}`)
        Console.log(`Last chunk ok: ${lastChunkOk ? "yes" : "no"}`)
        Console.log(`Middle chunks ok: ${middleChunksOk ? "yes" : "no"}`)
        false
      }
    } else {
      Console.error("FAIL: Large message didn't create multiple chunks")
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during large message chunking:", error)
    false
  }
}

// Test: Chunk metadata consistency
let testChunkMetadataConsistency = () => {
  let largeContent =
    Array.fromInitializer(~length=500, i => `data${i->Int.toString}`)->Array.join(" ")
  let largeMessage = createTestMessage(largeContent)

  try {
    let chunks = TransportMessage.createChunks(largeMessage, ~size=1000)

    if chunks->Array.length < 2 {
      Console.error("FAIL: Need multiple chunks for metadata test")
      false
    } else {
      // Extract chunk metadata
      let chunkData =
        chunks
        ->Array.mapWithIndex((transportMessage, index) => {
          switch transportMessage {
          | TransportMessage.IntermediateChunk(chunk) => Some((chunk, index))
          | TransportMessage.FinalChunk(chunk) => Some((chunk, index))
          | TransportMessage.UserMessage(_) => None
          }
        })
        ->Array.filter(Option.isSome)
        ->Array.map(Option.getUnsafe)

      // Check all chunks have same messageId
      let firstMessageId = switch chunkData[0] {
      | Some((chunk, _)) => Some(chunk->TransportMessage.Chunk.messageId)
      | None => None
      }

      let sameMessageId = switch firstMessageId {
      | Some(id) =>
        chunkData->Array.every(((chunk, _)) => chunk->TransportMessage.Chunk.messageId === id)
      | None => false
      }

      // Check indices are sequential
      let correctIndices =
        chunkData->Array.every(((chunk, arrayIndex)) =>
          chunk->TransportMessage.Chunk.index === arrayIndex
        )

      // Check total count is consistent
      let expectedTotal = chunks->Array.length
      let correctTotal =
        chunkData->Array.every(((chunk, _)) =>
          chunk->TransportMessage.Chunk.total === expectedTotal
        )

      // Check last chunk is marked as last
      let lastChunk = chunkData[chunkData->Array.length - 1]
      let lastChunkCorrect = switch lastChunk {
      | Some((chunk, _)) => chunk->TransportMessage.Chunk.isLast
      | None => false
      }

      if sameMessageId && correctIndices && correctTotal && lastChunkCorrect {
        Console.log("PASS: Chunk metadata is consistent")
        true
      } else {
        Console.error("FAIL: Chunk metadata inconsistency")
        Console.log(`Same message ID: ${sameMessageId ? "yes" : "no"}`)
        Console.log(`Correct indices: ${correctIndices ? "yes" : "no"}`)
        Console.log(`Correct total: ${correctTotal ? "yes" : "no"}`)
        Console.log(`Last chunk marked: ${lastChunkCorrect ? "yes" : "no"}`)
        false
      }
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during metadata test:", error)
    false
  }
}

// Test: Chunk reassembly
let testChunkReassembly = () => {
  let originalContent =
    Array.fromInitializer(~length=201, i => `test${i->Int.toString}`)->Array.join(" ")
  let originalMessage = createTestMessage(originalContent)
  let originalString = originalMessage->JSON.stringifyAny->Option.getOrThrow

  try {
    let chunks = TransportMessage.createChunks(originalMessage, ~size=500)

    // Extract actual chunks (not UserMessage)
    let actualChunks =
      chunks
      ->Array.mapWithIndex((transportMessage, _) => {
        switch transportMessage {
        | TransportMessage.IntermediateChunk(chunk) => Some(chunk)
        | TransportMessage.FinalChunk(chunk) => Some(chunk)
        | TransportMessage.UserMessage(_) => None
        }
      })
      ->Array.filter(Option.isSome)
      ->Array.map(chunk => Option.getOrThrow(chunk))

    if actualChunks->Array.length > 0 {
      // Reassemble
      let reassembled = actualChunks->TransportMessage.reassembleChunks

      if reassembled === originalString {
        Console.log("PASS: Chunk reassembly produces original message")
        true
      } else {
        Console.error("FAIL: Reassembled message doesn't match original")
        Console.log(`Original length: ${originalString->String.length->Int.toString}`)
        Console.log(`Reassembled length: ${reassembled->String.length->Int.toString}`)
        false
      }
    } else {
      Console.log("PASS: No chunks to reassemble (UserMessage case)")
      true
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during reassembly test:", error)
    false
  }
}

// Test: Chunk order independence
let testChunkOrderIndependence = () => {
  let originalContent =
    Array.fromInitializer(~length=101, i => `order${i->Int.toString}`)->Array.join(" ")
  let originalMessage = createTestMessage(originalContent)
  let originalString = originalMessage->JSON.stringifyAny->Option.getOrThrow

  try {
    let chunks = TransportMessage.createChunks(originalMessage, ~size=300)

    // Extract actual chunks
    let actualChunks =
      chunks
      ->Array.mapWithIndex((transportMessage, _) => {
        switch transportMessage {
        | TransportMessage.IntermediateChunk(chunk) => Some(chunk)
        | TransportMessage.FinalChunk(chunk) => Some(chunk)
        | TransportMessage.UserMessage(_) => None
        }
      })
      ->Array.filter(Option.isSome)
      ->Array.map(chunk => Option.getOrThrow(chunk))

    if actualChunks->Array.length > 2 {
      // Shuffle the chunks
      let shuffled = actualChunks->Array.copy
      // Simple shuffle - reverse the array
      shuffled->Array.reverse

      // Reassemble shuffled chunks
      let reassembled = shuffled->TransportMessage.reassembleChunks

      if reassembled === originalString {
        Console.log("PASS: Chunk order independence works")
        true
      } else {
        Console.error("FAIL: Chunk order independence failed")
        false
      }
    } else {
      Console.log("PASS: Not enough chunks for order independence test")
      true
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during order independence test:", error)
    false
  }
}

// Run all tests
let runTests = () => {
  let tests = [
    ("Small message creates UserMessage", testSmallMessageCreatesUserMessage),
    ("Large message creates chunks", testLargeMessageCreatesChunks),
    ("Chunk metadata consistency", testChunkMetadataConsistency),
    ("Chunk reassembly", testChunkReassembly),
    ("Chunk order independence", testChunkOrderIndependence),
  ]

  TestUtils.runSyncTests("TransportMessage Unit Tests", tests)
}

// Export for running
let main = runTests
