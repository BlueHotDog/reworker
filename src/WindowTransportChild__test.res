/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type browserWindow

@val external currentWindow: browserWindow = "window"
@get external parentWindow: browserWindow => browserWindow = "parent"

module Bindings = WindowTransport.Child.Make({
  type parentWindow = browserWindow
  let parentWindow = parentWindow(currentWindow)
  let parentOrigin = "http://127.0.0.1:4173"
  let requestTimeoutMs = 500
})

module TestRuntime = Runtime.Make(Bindings)
open WindowTransportBrowserMessages__test

let lastNotice = ref(None)

let handler:
  type response. (Types.message<response>, unit) => Response.t<response> =
  (message, _sender) => {
    switch message {
    | Ping(value) => Response.now(`child:${value}`)
    | AskReverse(value) => Response.later(TestRuntime.sendMessage(Reverse(value)))
    | Notice(value) => {
        lastNotice := Some(value)
        Response.none
      }
    | GetNotice => Response.now(lastNotice.contents)
    | Fail => JsError.throwWithMessage("Child handler failed")
    | Never => Response.none
    | Uncloneable(_) => Response.now("unexpected")
    | _ => Response.none
    }
  }

TestRuntime.OnMessage.addListener(handler)
Bindings.listen()->Result.getOrThrow
