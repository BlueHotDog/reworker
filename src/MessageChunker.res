/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

let defaultChunkSize = 31 * 1000 * 1000
let maxSize = defaultChunkSize

type textDecoder
@new external makeTextDecoder: unit => textDecoder = "TextDecoder"
@send external decode: (textDecoder, 'a) => string = "decode"

type textEncoder
@new external makeTextEncoder: unit => textEncoder = "TextEncoder"
@send external encode: (textEncoder, string) => Js.TypedArray2.Uint8Array.t = "encode"

module Chunk: {
  type t
  let total: t => int
  let index: t => int
  let messageId: t => Id.t
  let body: t => string
  let isLast: t => bool
  let make: (~index: int, ~total: int, ~body: string, ~messageId: Id.t) => t
} = {
  type t = {
    messageId: Id.t,
    index: int,
    total: int,
    body: string,
  }
  let total = t => t.total
  let index = t => t.index
  let messageId = t => t.messageId
  let body = t => t.body
  let isLast = t => t.index === t.total - 1
  let make = (~index, ~total, ~body, ~messageId) => {
    {
      messageId,
      index,
      total,
      body,
    }
  }
}

let decodeBinary = binary => {
  let decoder = makeTextDecoder()
  decoder->decode(binary)
}

let splitIntoChunks = (string, ~size=defaultChunkSize, ()) => {
  let encoder = makeTextEncoder()
  let encodedChunks = []

  let i = ref(0)
  let length = string->String.length
  while i.contents < length {
    let chunk = string->String.slice(~start=i.contents, ~end=i.contents + size)
    let encodeChunk = encoder->encode(chunk)
    encodedChunks->Array.push(encodeChunk)->ignore
    i := i.contents + size
  }
  encodedChunks
}

let chunk = (str: string, ~size=defaultChunkSize, ()) => {
  let rawChunks = str->splitIntoChunks(~size, ())->Array.map(decodeBinary)
  let messageId = Id.make() // Single ID shared by all chunks of this message
  let total = rawChunks->Array.length
  rawChunks->Array.mapWithIndex((chunkBody, index) => {
    Chunk.make(~index, ~total, ~body=chunkBody, ~messageId)
  })
}

let reassemble = (chunks: array<Chunk.t>) => {
  chunks->Array.reduce("", (acc, chunk) => acc ++ chunk->Chunk.body)
}

let shouldBeChunked = obj => {
  let messageAsString = obj->JSON.stringifyAny->Option.getOrThrow
  makeTextEncoder()->encode(messageAsString)->Js.TypedArray2.Uint8Array.byteLength > maxSize
}
