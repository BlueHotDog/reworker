/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Generic response type for message handlers in any JavaScript context
// Provides a unified interface for immediate, async, and no-response patterns

type t<'a> =
  | RespondNow('a) // Immediate response with value
  | RespondLater(promise<'a>) // Async response with promise
  | NoResponse // Handler processed message but no response needed

// Convenience constructors
let now = value => RespondNow(value)
let later = promise => RespondLater(promise)
let none = NoResponse

// Pattern matching helpers
let isImmediate = response => {
  switch response {
  | RespondNow(_) => true
  | RespondLater(_) => false
  | NoResponse => false
  }
}

let isAsync = response => {
  switch response {
  | RespondLater(_) => true
  | NoResponse => false
  | RespondNow(_) => false
  }
}

let hasResponse = response => {
  switch response {
  | NoResponse => false
  | RespondLater(_) => true
  | RespondNow(_) => true
  }
}
