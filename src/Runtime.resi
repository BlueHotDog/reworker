/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Generic Runtime interface for message passing with automatic chunking
// Users provide their own messaging bindings for different environments

module type RuntimeBindings = {
  type sender
  let sendMessage: 'a => Promise.t<'b>
  module OnMessage: {
    let addListener: (('a, sender, 'b => unit) => bool) => unit
    let removeListener: (('a, sender, 'b => unit) => bool) => unit
  }
  let getRuntimeId: unit => option<string>
}

module Make: (Bindings: RuntimeBindings) => {
  let sendMessage: Types.message<'a> => Promise.t<'a>
  let cast: Types.message<'a> => unit
  module OnMessage: {
    let addListener: ((Types.message<'a>, Bindings.sender) => Response.t<'a>) => unit
    let removeListener: ((Types.message<'a>, Bindings.sender) => Response.t<'a>) => unit
  }
  let isContextValid: unit => bool
}