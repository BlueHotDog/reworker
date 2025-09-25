/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// This module is internal to Runtime implementation
// Only expose functions needed by Runtime.res, TransportMessage.res, and tests

// Constant needed by TransportMessage.res line 41
let defaultChunkSize: int

// Functions needed by TransportMessage.res line 45
let decodeBinary: Js.TypedArray2.Uint8Array.t => string
let splitIntoChunks: (string, ~size: int=?, unit) => array<Js.TypedArray2.Uint8Array.t>

// Function needed by Runtime.res line 30
let shouldBeChunked: 'a => bool