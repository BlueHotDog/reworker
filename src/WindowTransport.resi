/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

module Parent: {
  module Make: (
    Config: {
      type targetWindow
      type loadEvent
      let targetOrigin: string
      let targetWindow: unit => targetWindow
      let addLoadListener: (loadEvent => unit) => unit
      let removeLoadListener: (loadEvent => unit) => unit
      let requestTimeoutMs: int
    },
  ) =>
  {
    type sender = unit
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
    let connect: unit => promise<unit>
  }
}

module Child: {
  module Make: (
    Config: {
      type parentWindow
      let parentWindow: parentWindow
      let parentOrigin: string
      let requestTimeoutMs: int
    },
  ) =>
  {
    type sender = unit
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
    let listen: unit => result<unit, string>
  }
}
