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
@send external encode: (textEncoder, string) => Uint8Array.t = "encode"

let decodeBinary = binary => {
  let decoder = makeTextDecoder()
  decoder->decode(binary)
}

let splitIntoChunks = (string, ~size=defaultChunkSize, ()) => {
  if size <= 0 {
    JsError.throwWithMessage("Chunk size must be greater than zero")
  }

  let encoder = makeTextEncoder()
  let encoded = encoder->encode(string)
  let encodedChunks = []

  let start = ref(0)
  let length = encoded->TypedArray.length
  while start.contents < length {
    let proposedEnd = start.contents + size
    let endIndex = ref(proposedEnd < length ? proposedEnd : length)
    let adjustingBoundary = ref(true)

    // Keep each boundary at the start of a UTF-8 code point.
    while (
      adjustingBoundary.contents && endIndex.contents < length && endIndex.contents > start.contents
    ) {
      let byte = encoded->TypedArray.get(endIndex.contents)->Option.getOr(0)
      if byte >= 128 && byte < 192 {
        endIndex := endIndex.contents - 1
      } else {
        adjustingBoundary := false
      }
    }

    if endIndex.contents === start.contents {
      endIndex := (proposedEnd < length ? proposedEnd : length)
      let findingBoundary = ref(true)
      while findingBoundary.contents && endIndex.contents < length {
        let byte = encoded->TypedArray.get(endIndex.contents)->Option.getOr(0)
        if byte >= 128 && byte < 192 {
          endIndex := endIndex.contents + 1
        } else {
          findingBoundary := false
        }
      }
    }

    let chunk = encoded->TypedArray.slice(~start=start.contents, ~end=endIndex.contents)
    encodedChunks->Array.push(chunk)->ignore
    start := endIndex.contents
  }
  encodedChunks
}

let shouldBeChunked = obj => {
  let messageAsString = obj->JSON.stringifyAny->Option.getOrThrow
  makeTextEncoder()->encode(messageAsString)->TypedArray.byteLength > maxSize
}
