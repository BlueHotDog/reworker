/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type session<'sender> = {
  connecting: unit => unit,
  opened: unit => unit,
  message: (Obj.t, 'sender) => unit,
  disconnected: string => unit,
}

type transport<'sender>
type limits = {
  requestTimeoutMs: int,
  maxMessageBytes: int,
  maxPendingRequests: int,
}
type context = Request(AbortSignal.t) | Cast
type status = Connecting | Open | Disconnected(string) | Closed(string)
type t<'sender>

let makeTransport: (
  ~postMessage: Obj.t => result<unit, string>,
  ~subscribe: (~onMessage: (Obj.t, 'sender) => unit, ~onDisconnect: string => unit) => unit => unit,
  ~maxChunkBytes: int,
) => transport<'sender>

let makeDynamicTransport: (
  ~postMessage: Obj.t => result<unit, string>,
  ~start: (~prepareSession: unit => session<'sender>) => unit,
  ~close: unit => unit,
  ~maxChunkBytes: int,
) => transport<'sender>

let make: (
  transport<'sender>,
  ~limits: limits,
  ~handler: (Types.message<'response>, 'sender, context) => Response.t<'response>,
) => t<'sender>
let sendMessage: (
  t<'sender>,
  Types.message<'response>,
  ~signal: AbortSignal.t=?,
) => Promise.t<'response>
let cast: (t<'sender>, Types.message<unit>) => unit
let status: t<'sender> => status
let onStatus: (t<'sender>, status => unit) => unit => unit
let whenOpen: t<'sender> => Promise.t<unit>
let close: t<'sender> => unit
