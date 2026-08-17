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
  let make: (~messageId: Id.t, ~index: int, ~total: int, ~body: string) => chunk
  let messageId: chunk => Id.t
  let index: chunk => int
  let total: chunk => int
  let isLast: chunk => bool
  let body: chunk => string
}

// GADT for transport messages - needed by Runtime.res
type rec t<'response> =
  | UserMessage(Types.message<'response>): t<'response>
  | IntermediateChunk(chunk): t<chunkAck>
  | FinalChunk(chunk): t<'response>

// Functions needed by Runtime.res and RequestHandler.res
let createChunks: ('a, ~size: int=?) => array<t<chunkAck>>
let createRawChunks: ('a, ~size: int) => array<chunk>
let reassembleChunks: array<chunk> => string
let messageId: t<chunkAck> => option<Id.t>
let isIntermediate: t<chunkAck> => bool
