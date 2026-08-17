/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type transport<'sender, 'extension> = {
  requestTimeoutMs: int,
  maxMessageBytes: int,
  maxPendingRequests: int,
  maxChunkBytes: int,
  postMessage: Obj.t => result<unit, string>,
  addMessageListener: ((Obj.t, 'sender) => unit) => unit,
  removeMessageListener: ((Obj.t, 'sender) => unit) => unit,
  addOpenListener: (unit => unit) => unit,
  removeOpenListener: (unit => unit) => unit,
  addCloseListener: (string => unit) => unit,
  removeCloseListener: (string => unit) => unit,
  isOpen: unit => bool,
  isCurrentSender: 'sender => bool,
  senderKey: 'sender => string,
  close: unit => unit,
  extension: 'extension,
}

type t<'sender>

let make: transport<'sender, 'extension> => t<'sender>
let sendMessage: (
  t<'sender>,
  Types.message<'response>,
  ~signal: AbortSignal.t=?,
) => Promise.t<'response>
let cast: (t<'sender>, Types.message<'response>) => unit

module OnMessage: {
  let addListener: (
    t<'sender>,
    (Types.message<'response>, 'sender, option<AbortSignal.t>) => Response.t<'response>,
  ) => unit
  let removeListener: (
    t<'sender>,
    (Types.message<'response>, 'sender, option<AbortSignal.t>) => Response.t<'response>,
  ) => unit
}

let isContextValid: t<'sender> => bool
let onOpen: (t<'sender>, unit => unit) => unit => unit
let onClose: (t<'sender>, string => unit) => unit => unit
let onReconnect: (t<'sender>, unit => unit) => unit => unit
let close: t<'sender> => unit
