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

type assembly = {
  chunks: Map.t<int, TransportMessage.chunk>,
  total: int,
  mutable bytes: int,
  mutable timeoutId: timeoutId,
}

@scope("Number") @val external isSafeInteger: Obj.t => bool = "isSafeInteger"

let isNonEmptyString = value => {
  Type.typeof(Obj.magic(value)) === #string && (Obj.magic(value): string) !== ""
}

type t = {
  assemblies: Map.t<string, Map.t<Id.t, assembly>>,
  timeoutMs: int,
  maxMessageBytes: int,
  maxPendingRequests: int,
  maxChunkBytes: int,
  mutable storedBytes: int,
  mutable assemblyCount: int,
}

let makeState = (~timeoutMs, ~maxMessageBytes, ~maxPendingRequests, ~maxChunkBytes) => {
  assemblies: Map.make(),
  timeoutMs,
  maxMessageBytes,
  maxPendingRequests,
  maxChunkBytes,
  storedBytes: 0,
  assemblyCount: 0,
}
let clear = state => {
  state.assemblies->Map.forEach(assemblies => {
    assemblies->Map.forEach(assembly => clearTimeout(assembly.timeoutId))
    assemblies->Map.clear
  })
  state.assemblies->Map.clear
  state.storedBytes = 0
  state.assemblyCount = 0
}

let cancel = (state, senderKey, messageId) => {
  switch state.assemblies
  ->Map.get(senderKey)
  ->Option.flatMap(assemblies => {
    assemblies->Map.get(messageId)->Option.map(assembly => (assemblies, assembly))
  }) {
  | Some((assemblies, assembly)) => {
      clearTimeout(assembly.timeoutId)
      assemblies->Map.delete(messageId)->ignore
      state.storedBytes = state.storedBytes - assembly.bytes
      state.assemblyCount = state.assemblyCount - 1
      if assemblies->Map.size === 0 {
        state.assemblies->Map.delete(senderKey)->ignore
      }
    }
  | None => ()
  }
}

let senderAssemblies = (state, senderKey) => {
  switch state.assemblies->Map.get(senderKey) {
  | Some(assemblies) => assemblies
  | None => {
      let assemblies = Map.make()
      state.assemblies->Map.set(senderKey, assemblies)
      assemblies
    }
  }
}

let removeAssembly = (state, senderKey, assemblies: Map.t<Id.t, assembly>, messageId) => {
  switch assemblies->Map.get(messageId) {
  | Some(assembly) => {
      clearTimeout(assembly.timeoutId)
      assemblies->Map.delete(messageId)->ignore
      state.storedBytes = state.storedBytes - assembly.bytes
      state.assemblyCount = state.assemblyCount - 1
      if assemblies->Map.size === 0 {
        state.assemblies->Map.delete(senderKey)->ignore
      }
      Some(assembly)
    }
  | None => None
  }
}

let validateChunk = (state, chunk, ~final) => {
  let messageId = chunk->TransportMessage.Chunk.messageId
  let index = chunk->TransportMessage.Chunk.index
  let total = chunk->TransportMessage.Chunk.total
  let isLast = chunk->TransportMessage.Chunk.isLast
  let body = chunk->TransportMessage.Chunk.body
  if (
    !isNonEmptyString(messageId) ||
    !isSafeInteger(Obj.magic(index)) ||
    !isSafeInteger(Obj.magic(total)) ||
    !isNonEmptyString(body)
  ) {
    Error("Malformed chunk sequence")
  } else {
    let bytes = body->MessageChunker.stringByteLength
    let maxChunks = MessageChunker.chunkCountLimit(
      ~maxMessageBytes=state.maxMessageBytes,
      ~maxChunkBytes=state.maxChunkBytes,
    )
    if total <= 0 || total > maxChunks || index < 0 || index >= total || final !== isLast {
      Error("Malformed chunk sequence")
    } else if bytes > state.maxChunkBytes {
      Error("Chunk exceeds maxChunkBytes")
    } else if !isLast && bytes < state.maxChunkBytes - 3 {
      Error("Malformed chunk sequence")
    } else {
      Ok(bytes)
    }
  }
}

let validateOrThrow = (state, senderKey, messageId, chunk, ~final) => {
  switch validateChunk(state, chunk, ~final) {
  | Ok(bytes) => bytes
  | Error(message) => {
      cancel(state, senderKey, messageId)
      JsError.throwWithMessage(message)
    }
  }
}

let rejectAssembly = (state, senderKey, messageId, message) => {
  cancel(state, senderKey, messageId)
  JsError.throwWithMessage(message)
}

let addChunk = (state, ~senderKey, chunk, ~final) => {
  let messageId = chunk->TransportMessage.Chunk.messageId
  let chunkBytes = validateOrThrow(state, senderKey, messageId, chunk, ~final)
  if final {
    let assemblies = switch state.assemblies->Map.get(senderKey) {
    | Some(assemblies) => assemblies
    | None => JsError.throwWithMessage("Malformed chunk sequence")
    }
    let previousAssembly = removeAssembly(state, senderKey, assemblies, messageId)
    let previousChunks = switch previousAssembly {
    | Some(assembly) if assembly.total === chunk->TransportMessage.Chunk.total => assembly.chunks
    | Some(_) | None => JsError.throwWithMessage("Malformed chunk sequence")
    }
    let previousBytes = previousAssembly->Option.mapOr(0, assembly => assembly.bytes)
    if (
      previousBytes + chunkBytes > state.maxMessageBytes ||
        previousChunks->Map.size + 1 !== chunk->TransportMessage.Chunk.total
    ) {
      JsError.throwWithMessage("Malformed chunk sequence")
    }
    let chunks = []
    previousChunks->Map.forEach(chunk => chunks->Array.push(chunk)->ignore)
    chunks->Array.push(chunk)->ignore
    Some(chunks->TransportMessage.reassembleChunks)
  } else {
    let assemblies = senderAssemblies(state, senderKey)
    switch assemblies->Map.get(messageId) {
    | Some(assembly) => {
        if (
          assembly.total !== chunk->TransportMessage.Chunk.total ||
            assembly.chunks->Map.has(chunk->TransportMessage.Chunk.index)
        ) {
          rejectAssembly(state, senderKey, messageId, "Malformed chunk sequence")
        }
        if assembly.bytes + chunkBytes > state.maxMessageBytes {
          rejectAssembly(state, senderKey, messageId, "Message exceeds maxMessageBytes")
        }
        if state.storedBytes + chunkBytes > state.maxMessageBytes {
          rejectAssembly(state, senderKey, messageId, "Chunk allocation exceeds maxMessageBytes")
        }
        clearTimeout(assembly.timeoutId)
        assembly.chunks->Map.set(chunk->TransportMessage.Chunk.index, chunk)
        assembly.bytes = assembly.bytes + chunkBytes
        state.storedBytes = state.storedBytes + chunkBytes
        assembly.timeoutId = setTimeout(() => {
          removeAssembly(state, senderKey, assemblies, messageId)->ignore
        }, state.timeoutMs)
      }
    | None => {
        if state.assemblyCount >= state.maxPendingRequests {
          rejectAssembly(state, senderKey, messageId, "Too many pending chunk assemblies")
        }
        if state.storedBytes + chunkBytes > state.maxMessageBytes {
          rejectAssembly(state, senderKey, messageId, "Chunk allocation exceeds maxMessageBytes")
        }
        let timeoutId = setTimeout(() => {
          removeAssembly(state, senderKey, assemblies, messageId)->ignore
        }, state.timeoutMs)
        let chunks = Map.make()
        chunks->Map.set(chunk->TransportMessage.Chunk.index, chunk)
        assemblies->Map.set(
          messageId,
          {
            chunks,
            total: chunk->TransportMessage.Chunk.total,
            bytes: chunkBytes,
            timeoutId,
          },
        )
        state.storedBytes = state.storedBytes + chunkBytes
        state.assemblyCount = state.assemblyCount + 1
      }
    }
    None
  }
}

let make:
  type a. (
    t,
    ~userHandler: (Types.message<a>, 'sender, option<AbortSignal.t>) => Response.t<a>,
    TransportMessage.t<a>,
    'sender,
    string,
    option<AbortSignal.t>,
  ) => Response.t<a> =
  (state, ~userHandler, transportMessage, sender, senderKey, signal) =>
    switch transportMessage {
    | TransportMessage.UserMessage(userMessage) => {
        if userMessage->MessageChunker.byteLength > state.maxMessageBytes {
          JsError.throwWithMessage("Message exceeds maxMessageBytes")
        }
        userHandler(userMessage, sender, signal)
      }
    | TransportMessage.IntermediateChunk(chunk) => {
        addChunk(state, ~senderKey, chunk, ~final=false)->ignore
        Response.RespondNow(TransportMessage.ChunkAck(chunk->TransportMessage.Chunk.messageId))
      }
    | TransportMessage.FinalChunk(chunk) =>
      switch addChunk(state, ~senderKey, chunk, ~final=true) {
      | Some(message) => userHandler(message->JSON.parseOrThrow->Obj.magic, sender, signal)
      | None => JsError.throwWithMessage("Malformed chunk sequence")
      }
    }
