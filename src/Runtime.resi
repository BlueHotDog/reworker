/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

module type RuntimeBindings = {
  type sender
  let requestTimeoutMs: int
  let postMessage: 'a => result<unit, string>
  module OnMessage: {
    let addListener: (('a, sender) => unit) => unit
    let removeListener: (('a, sender) => unit) => unit
  }
  module OnClose: {
    let addListener: (string => unit) => unit
  }
  let isOpen: unit => bool
  let close: unit => unit
}

module Make: (Bindings: RuntimeBindings) =>
{
  let sendMessage: Types.message<'a> => Promise.t<'a>
  let cast: Types.message<'a> => unit
  module OnMessage: {
    let addListener: ((Types.message<'a>, Bindings.sender) => Response.t<'a>) => unit
    let removeListener: ((Types.message<'a>, Bindings.sender) => Response.t<'a>) => unit
  }
  let isContextValid: unit => bool
  let close: unit => unit
}
