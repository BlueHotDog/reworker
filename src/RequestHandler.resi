/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// This module is internal to Runtime implementation
// Only expose functions needed by Runtime.res

type t

let makeState: (
  ~timeoutMs: int,
  ~maxMessageBytes: int,
  ~maxPendingRequests: int,
  ~maxChunkBytes: int,
) => t
let clear: t => unit
let cancel: (t, string, Id.t) => unit

let make: (
  t,
  ~userHandler: (Types.message<'a>, 'sender, option<AbortSignal.t>) => Response.t<'a>,
  TransportMessage.t<'a>,
  'sender,
  string,
  Id.t,
  option<AbortSignal.t>,
) => Response.t<'a>
