/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Transport-level message types for internal chunking
// These types are invisible to users - only used by Runtime implementation

// Internal chunk data structure
type chunk = {
  messageId: Id.t,
  index: int,
  total: int,
  body: string,
}

// Chunk acknowledgment response type
type chunkAck = ChunkAck(Id.t)

// Transport message type - handles both user messages and internal chunks
type rec t<'response> =
  | UserMessage(Types.message<'response>): t<'response>
  | IntermediateChunk(chunk): t<chunkAck>
  | FinalChunk(chunk): t<'response> // Final chunk returns original response type!

// Chunk utilities
module Chunk = {
  let make = (~messageId, ~index, ~total, ~body) => {
    {messageId, index, total, body}
  }

  let messageId = chunk => chunk.messageId
  let index = chunk => chunk.index
  let total = chunk => chunk.total
  let body = chunk => chunk.body
  let isLast = chunk => chunk.index === chunk.total - 1
}

// Create chunks from a large message string
// Returns array of transport messages with proper response types
let createChunks = (message: 'a, ~size=MessageChunker.defaultChunkSize) => {
  let messageString = message->JSON.stringifyAny->Option.getOrThrow
  let messageId = Id.make()
  let rawChunks =
    messageString->MessageChunker.splitIntoChunks(~size, ())->Array.map(MessageChunker.decodeBinary)

  rawChunks->Array.mapWithIndex((body, index) => {
    let chunk = Chunk.make(~messageId, ~index, ~total=rawChunks->Array.length, ~body)

    if index === rawChunks->Array.length - 1 {
      FinalChunk(chunk)
    } else {
      IntermediateChunk(chunk)
    }
  })
}

let reassembleChunks = (chunks: array<chunk>) => {
  chunks->Array.map(chunk => chunk.body)->Array.join("")
}
