/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type preparedJson = {
  value: Obj.t,
  encoded: option<Uint8Array.t>,
}

let maxChunksPerMessage: int
let prepareJsonWithin: ('a, ~maxBytes: int) => option<preparedJson>
let stringByteLength: string => int
let chunkPrepared: (preparedJson, ~size: int) => option<array<string>>
