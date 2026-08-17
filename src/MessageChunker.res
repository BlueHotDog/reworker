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

type seenObjects
@new external makeSeenObjects: unit => seenObjects = "WeakSet"
@send external hasSeen: (seenObjects, Obj.t) => bool = "has"
@send external addSeen: (seenObjects, Obj.t) => unit = "add"
@send external removeSeen: (seenObjects, Obj.t) => bool = "delete"
@scope("Array") @val external isArray: Obj.t => bool = "isArray"
@scope("ArrayBuffer") @val external isArrayBufferView: Obj.t => bool = "isView"
@scope("Number") @val external isFiniteNumber: Obj.t => bool = "isFinite"
@scope("Object") @val external objectValues: Obj.t => array<Obj.t> = "values"
@scope("Object") @val external getPrototypeOf: Obj.t => Nullable.t<Obj.t> = "getPrototypeOf"
@val external objectPrototype: Obj.t = "Object.prototype"
type propertyDescriptor
type propertyGetter
@val external arrayBufferPrototype: Obj.t = "ArrayBuffer.prototype"
@scope("Object") @val
external getOwnPropertyDescriptor: (Obj.t, string) => propertyDescriptor =
  "getOwnPropertyDescriptor"
@get external propertyGetter: propertyDescriptor => propertyGetter = "get"
@send external callPropertyGetter: (propertyGetter, Obj.t) => int = "call"

let isArrayBuffer = value => {
  try {
    let getter = getOwnPropertyDescriptor(arrayBufferPrototype, "byteLength")->propertyGetter
    callPropertyGetter(getter, value)->ignore
    true
  } catch {
  | _ => false
  }
}

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

let rec validateJsonValue = (value, seen, ~root) => {
  switch Type.typeof(value) {
  | #undefined =>
    if !root {
      JsError.throwWithMessage("Payload must be JSON-compatible")
    }
  | #function | #symbol | #bigint => JsError.throwWithMessage("Payload must be JSON-compatible")
  | #object => {
      let nullable: Nullable.t<Obj.t> = Obj.magic(value)
      switch nullable->Nullable.toOption {
      | None => ()
      | Some(object) => {
          if isArrayBuffer(object) || isArrayBufferView(object) {
            JsError.throwWithMessage("Payload must be JSON-compatible")
          }
          if seen->hasSeen(object) {
            JsError.throwWithMessage("Payload must be JSON-compatible")
          }
          seen->addSeen(object)
          if !isArray(object) {
            switch object->getPrototypeOf->Nullable.toOption {
            | Some(prototype) if prototype === objectPrototype => ()
            | Some(_) => JsError.throwWithMessage("Payload must be JSON-compatible")
            | None => ()
            }
          }
          object->objectValues->Array.forEach(item => validateJsonValue(item, seen, ~root=false))
          seen->removeSeen(object)->ignore
        }
      }
    }
  | #number =>
    if !isFiniteNumber(value) {
      JsError.throwWithMessage("Payload must be JSON-compatible")
    }
  | #boolean | #string => ()
  }
}

let byteLength = obj => {
  validateJsonValue(Obj.magic(obj), makeSeenObjects(), ~root=true)
  switch obj->JSON.stringifyAny {
  | Some(messageAsString) => makeTextEncoder()->encode(messageAsString)->TypedArray.byteLength
  | None => 0
  }
}

let normalizeJson = value => {
  validateJsonValue(Obj.magic(value), makeSeenObjects(), ~root=true)
  switch value->JSON.stringifyAny {
  | Some(json) => json->JSON.parseOrThrow->Obj.magic
  | None => Obj.magic(value)
  }
}

let stringByteLength = value => makeTextEncoder()->encode(value)->TypedArray.byteLength

let maxChunksPerMessage = 10_000

let configuredChunkCount = (~maxMessageBytes, ~maxChunkBytes) => {
  let minimumChunkBytes = maxChunkBytes - 3
  (maxMessageBytes - 1) / minimumChunkBytes + 1
}

let chunkCountLimit = (~maxMessageBytes, ~maxChunkBytes) => {
  let configured = configuredChunkCount(~maxMessageBytes, ~maxChunkBytes)
  configured < maxChunksPerMessage ? configured : maxChunksPerMessage
}

let shouldBeChunked = (obj, ~size=maxSize) => {
  obj->byteLength > size
}
