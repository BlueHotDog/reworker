/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

let aborted: t => bool
let addEventListener: (t, string, unit => unit) => unit
let removeEventListener: (t, string, unit => unit) => unit
