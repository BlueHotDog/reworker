/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// RequestHandler - Transport Message Processing for Runtime
//
// PURPOSE:
// Processes transport messages (user messages + internal chunks) and handles
// chunk reassembly transparently. Works with the new TransportMessage.t system.
//
// FLOW:
// 1. TransportMessage.UserMessage: Forward directly to user handler
// 2. TransportMessage.ChunkMessage: Collect chunks, reassemble when complete, forward to user handler

// Simple chunk collection - store chunks by their shared message ID
let chunkMap: Map.t<Id.t, array<TransportMessage.chunk>> = Map.make()

let make:
  type a. (
    ~userHandler: (Types.message<a>, 'sender) => Response.t<a>,
    TransportMessage.t<a>,
    'sender,
  ) => Response.t<a> =
  (~userHandler, transportMessage, sender) => {
    switch transportMessage {
    // Direct user message - forward to user handler
    | TransportMessage.UserMessage(userMessage) => userHandler(userMessage, sender)

    // Intermediate chunk - store and acknowledge
    | TransportMessage.IntermediateChunk(chunk) =>
      let messageId = chunk->TransportMessage.Chunk.messageId
      let existingChunks = chunkMap->Map.get(messageId)->Option.getOr([])
      let updatedChunks = existingChunks->Array.concat([chunk])
      chunkMap->Map.set(messageId, updatedChunks)

      // Return chunk acknowledgment immediately
      let chunkAck = TransportMessage.ChunkAck(messageId)
      Response.RespondNow(chunkAck)

    | TransportMessage.FinalChunk(chunk) =>
      // Final chunk - reassemble and forward to user handler
      let messageId = chunk->TransportMessage.Chunk.messageId
      let previousChunks: array<TransportMessage.chunk> =
        chunkMap->Map.get(messageId)->Option.getOr([])
      let allChunks = previousChunks->Array.concat([chunk])

      // Reassemble original message string
      let reassembledString = allChunks->TransportMessage.reassembleChunks
      let originalMessage = reassembledString->JSON.parseOrThrow

      // Clean up chunk storage
      assert(chunkMap->Map.delete(messageId) == true)

      // Forward complete message to user handler - return their response directly!
      // Note: Type system requires Obj.magic due to GADT limitations
      userHandler(originalMessage->Obj.magic, sender)
    }
  }
