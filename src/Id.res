/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t = string

@val external randomUUID: unit => string = "crypto.randomUUID"

let make = randomUUID
let toString = v => v
