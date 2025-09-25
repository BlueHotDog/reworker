/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// This module is internal to Runtime implementation
// Only expose functions needed by Runtime.res

type t

// Functions needed by Runtime.res
let make: unit => t
let set: (t, 'a, 'b) => unit
let get: (t, 'a) => option<'c>
let delete: (t, 'a) => unit