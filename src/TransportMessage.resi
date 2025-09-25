/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// This module is internal to Runtime implementation
// Only expose types and functions needed by Runtime.res

type chunk
type chunkAck = ChunkAck(Id.t)

// Chunk utility module - needed by RequestHandler.res and tests
module Chunk: {
  let messageId: chunk => Id.t
  let index: chunk => int
  let total: chunk => int
  let isLast: chunk => bool
}

// GADT for transport messages - needed by Runtime.res
type rec t<'response> =
  | UserMessage(Types.message<'response>): t<'response>
  | IntermediateChunk(chunk): t<chunkAck>
  | FinalChunk(chunk): t<'response>

// Functions needed by Runtime.res and RequestHandler.res
let createChunks: ('a, ~size: int=?) => array<t<chunkAck>>
let reassembleChunks: array<chunk> => string