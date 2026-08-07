/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

@val external current: t = "window"
@send external postMessage: (t, 'a, string, array<MessagePort.t>) => unit = "postMessage"
@send external addEventListener: (t, string, 'event => unit) => unit = "addEventListener"
@send external removeEventListener: (t, string, 'event => unit) => unit = "removeEventListener"
