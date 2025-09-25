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

let shouldBeChunked = obj => {
  let messageAsString = obj->JSON.stringifyAny->Option.getOrThrow
  makeTextEncoder()->encode(messageAsString)->Js.TypedArray2.Uint8Array.byteLength > maxSize
}
