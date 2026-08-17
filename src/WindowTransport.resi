/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

module Parent: {
  type config<'targetWindow, 'loadEvent> = {
    targetWindow: 'targetWindow,
    targetOrigin: string,
    isTargetLoaded: unit => bool,
    addLoadListener: ('loadEvent => unit) => unit,
    removeLoadListener: ('loadEvent => unit) => unit,
    requestTimeoutMs: int,
    maxMessageBytes: int,
    maxPendingRequests: int,
    maxChunkBytes: int,
  }

  type extension<'targetWindow, 'loadEvent>
  type t<'targetWindow, 'loadEvent> = Runtime.transport<int, extension<'targetWindow, 'loadEvent>>

  let make: config<'targetWindow, 'loadEvent> => t<'targetWindow, 'loadEvent>
  let connect: t<'targetWindow, 'loadEvent> => promise<unit>
}

module Child: {
  type config<'parentWindow> = {
    parentWindow: 'parentWindow,
    parentOrigin: string,
    requestTimeoutMs: int,
    maxMessageBytes: int,
    maxPendingRequests: int,
    maxChunkBytes: int,
  }

  type extension<'parentWindow>
  type t<'parentWindow> = Runtime.transport<int, extension<'parentWindow>>

  let make: config<'parentWindow> => t<'parentWindow>
  let listen: t<'parentWindow> => result<unit, string>
}
