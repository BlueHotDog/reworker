/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Generic response type for message handlers in any JavaScript context
// Provides unified interface for immediate, async, and no-response patterns

type t<'a> =
  | RespondNow('a)           // Immediate response with value
  | RespondLater(promise<'a>) // Async response with promise
  | NoResponse               // Handler processed message but no response needed

// Convenience constructors
let now: 'a => t<'a>
let later: promise<'a> => t<'a>
let none: t<'a>

// Pattern matching helpers
let isImmediate: t<'a> => bool
let isAsync: t<'a> => bool
let hasResponse: t<'a> => bool