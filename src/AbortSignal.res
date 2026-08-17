/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

@get external aborted: t => bool = "aborted"
@send external addEventListener: (t, string, unit => unit) => unit = "addEventListener"
@send external removeEventListener: (t, string, unit => unit) => unit = "removeEventListener"
