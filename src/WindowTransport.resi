/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

module Parent: {
  type config<'targetWindow> = {
    targetWindow: 'targetWindow,
    targetOrigin: string,
    channel: string,
    subscribeLoad: (unit => unit) => unit => unit,
    connectionTimeoutMs: int,
    maxChunkBytes: int,
  }

  let make: config<'targetWindow> => Runtime.transport<unit>
}

module Child: {
  type config<'parentWindow> = {
    parentWindow: 'parentWindow,
    parentOrigin: string,
    channel: string,
    maxChunkBytes: int,
  }

  let make: config<'parentWindow> => Runtime.transport<unit>
}
