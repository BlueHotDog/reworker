/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// This module is internal to Runtime implementation
// Only expose functions needed by Runtime.res

// Function needed by Runtime.res line 66
let make: (
  ~userHandler: (Types.message<'a>, 'sender) => Response.t<'a>,
  TransportMessage.t<'a>,
  'sender,
) => Response.t<'a>