/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type preparedJson = {
  value: Obj.t,
  encoded: option<Uint8Array.t>,
  byteLength: int,
}

let defaultChunkSize: int
let maxChunksPerMessage: int
let prepareJson: 'a => preparedJson
let stringByteLength: string => int
let splitEncodedIntoChunks: (Uint8Array.t, ~size: int) => array<Uint8Array.t>
let splitIntoChunks: (string, ~size: int=?, unit) => array<Uint8Array.t>
let decodeBinary: Uint8Array.t => string
