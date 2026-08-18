/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

let aborted: t => bool
let onAbort: (t, unit => unit) => unit => unit
