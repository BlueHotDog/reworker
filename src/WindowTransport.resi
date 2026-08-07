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
    include Runtime.RuntimeBindings with type sender = unit
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
    include Runtime.RuntimeBindings with type sender = unit
    let listen: unit => result<unit, string>
  }
}
