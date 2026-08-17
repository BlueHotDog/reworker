/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// This module is internal to Runtime implementation
// Only expose functions needed by Runtime.res, TransportMessage.res, and tests

// Constant needed by TransportMessage.res line 41
let defaultChunkSize: int

// Functions needed by TransportMessage.res line 45
let decodeBinary: Uint8Array.t => string
let splitIntoChunks: (string, ~size: int=?, unit) => array<Uint8Array.t>
let byteLength: 'a => int
let stringByteLength: string => int
let maxChunksPerMessage: int
let configuredChunkCount: (~maxMessageBytes: int, ~maxChunkBytes: int) => int
let chunkCountLimit: (~maxMessageBytes: int, ~maxChunkBytes: int) => int
let normalizeJson: 'a => Obj.t

// Function needed by Runtime.res line 30
let shouldBeChunked: ('a, ~size: int=?) => bool
