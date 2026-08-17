/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

let defaultChunkSize = 31 * 1000 * 1000
let maxChunksPerMessage = 10_000

type preparedJson = {
  value: Obj.t,
  encoded: option<Uint8Array.t>,
  byteLength: int,
}

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
          if isArrayBuffer(object) || isArrayBufferView(object) || seen->hasSeen(object) {
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
  | #number if !isFiniteNumber(value) => JsError.throwWithMessage("Payload must be JSON-compatible")
  | #number | #boolean | #string => ()
  }
}

let stringByteLength = value => makeTextEncoder()->encode(value)->TypedArray.byteLength

let prepareJson = value => {
  validateJsonValue(Obj.magic(value), makeSeenObjects(), ~root=true)
  switch value->JSON.stringifyAny {
  | Some(json) => {
      let encoded = makeTextEncoder()->encode(json)
      {
        value: json->JSON.parseOrThrow->Obj.magic,
        encoded: Some(encoded),
        byteLength: encoded->TypedArray.byteLength,
      }
    }
  | None => {value: Obj.magic(value), encoded: None, byteLength: 0}
  }
}

let splitEncodedIntoChunks = (encoded, ~size) => {
  if size <= 0 {
    JsError.throwWithMessage("Chunk size must be greater than zero")
  }
  let chunks = []
  let start = ref(0)
  let length = encoded->TypedArray.length
  while start.contents < length {
    let proposedEnd = start.contents + size
    let endIndex = ref(proposedEnd < length ? proposedEnd : length)
    let adjustingBoundary = ref(true)
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
    chunks
    ->Array.push(encoded->TypedArray.slice(~start=start.contents, ~end=endIndex.contents))
    ->ignore
    start := endIndex.contents
  }
  chunks
}

let splitIntoChunks = (string, ~size=defaultChunkSize, ()) =>
  makeTextEncoder()->encode(string)->splitEncodedIntoChunks(~size)

let decodeBinary = binary => makeTextDecoder()->decode(binary)
