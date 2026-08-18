/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

@send external start: t => unit = "start"
@send external close: t => unit = "close"
@send external postMessage: (t, 'a) => unit = "postMessage"
@send external addEventListener: (t, string, 'event => unit) => unit = "addEventListener"
@send external removeEventListener: (t, string, 'event => unit) => unit = "removeEventListener"
