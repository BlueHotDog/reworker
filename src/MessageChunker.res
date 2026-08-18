/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

let maxChunksPerMessage = 10_000

type preparedJson = {
  value: Obj.t,
  encoded: option<Uint8Array.t>,
}

type textDecoder
type textDecoderOptions
@obj external makeTextDecoderOptions: (~fatal: bool, ~ignoreBOM: bool) => textDecoderOptions = ""
@new external makeTextDecoder: (string, textDecoderOptions) => textDecoder = "TextDecoder"
@send external decode: (textDecoder, Uint8Array.t) => string = "decode"
type textEncoder
@new external makeTextEncoder: unit => textEncoder = "TextEncoder"
@send external encode: (textEncoder, string) => Uint8Array.t = "encode"

let stringByteLength = value => makeTextEncoder()->encode(value)->TypedArray.byteLength

let prepareJsonWithin = (value, ~maxBytes) => {
  switch Type.typeof(Obj.magic(value)) {
  | #undefined => Some({value: Obj.magic(value), encoded: None})
  | _ =>
    switch value->JSON.stringifyAny {
    | Some(json) => {
        let encoded = makeTextEncoder()->encode(json)
        if encoded->TypedArray.byteLength > maxBytes {
          None
        } else {
          Some({value: json->JSON.parseOrThrow->Obj.magic, encoded: Some(encoded)})
        }
      }
    | None => JsError.throwWithMessage("Payload must be JSON-compatible")
    }
  }
}

let rec previousUtf8Boundary = (encoded, index) => {
  switch encoded->TypedArray.get(index) {
  | Some(byte) if byte >= 128 && byte < 192 => previousUtf8Boundary(encoded, index - 1)
  | Some(_) | None => index
  }
}

let splitEncodedIntoChunks = (encoded, ~size) => {
  let chunks = []
  let start = ref(0)
  let length = encoded->TypedArray.length
  let decoder = makeTextDecoder("utf-8", makeTextDecoderOptions(~fatal=true, ~ignoreBOM=true))
  while start.contents < length {
    if chunks->Array.length >= maxChunksPerMessage {
      JsError.throwWithMessage("Too many chunks")
    }
    let proposedEnd = start.contents + size
    let endIndex = previousUtf8Boundary(encoded, proposedEnd < length ? proposedEnd : length)
    chunks
    ->Array.push(decoder->decode(encoded->TypedArray.slice(~start=start.contents, ~end=endIndex)))
    ->ignore
    start := endIndex
  }
  chunks
}

let chunkPrepared = (prepared, ~size) => {
  if size < 4 {
    JsError.throwWithMessage("Chunk size must be at least four bytes")
  }
  switch prepared.encoded {
  | None => None
  | Some(encoded) if encoded->TypedArray.byteLength <= size => None
  | Some(encoded) => encoded->splitEncodedIntoChunks(~size)->Some
  }
}
