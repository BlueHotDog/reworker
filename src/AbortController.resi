/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

let make: unit => t
let signal: t => AbortSignal.t
let abort: t => unit
