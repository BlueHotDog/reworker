/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type t

@get external aborted: t => bool = "aborted"
@send external addEventListener: (t, string, unit => unit) => unit = "addEventListener"
@send external removeEventListener: (t, string, unit => unit) => unit = "removeEventListener"

let onAbort = (signal, listener) => {
  let called = ref(false)
  let notify = () => {
    if !called.contents {
      called := true
      listener()
    }
  }
  signal->addEventListener("abort", notify)
  if signal->aborted {
    notify()
  }
  let subscribed = ref(true)
  () => {
    if subscribed.contents {
      subscribed := false
      signal->removeEventListener("abort", notify)
    }
  }
}
