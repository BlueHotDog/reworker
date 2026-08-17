/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type browserWindow

@val external currentWindow: browserWindow = "window"
@get external parentWindow: browserWindow => browserWindow = "parent"

let transport = WindowTransport.Child.make({
  parentWindow: parentWindow(currentWindow),
  parentOrigin: "http://127.0.0.1:4173",
  requestTimeoutMs: 500,
  maxMessageBytes: 2_000_000,
  maxPendingRequests: 100,
  maxChunkBytes: 100_000,
})

let runtime = Runtime.make(transport)
open WindowTransportBrowserMessages__test

let lastNotice = ref(None)
let cancellationCount = ref(0)
let cancellationStartCount = ref(0)

let handler:
  type response. (Types.message<response>, int, option<AbortSignal.t>) => Response.t<response> =
  (message, _sender, signal) => {
    switch message {
    | Ping(value) => Response.now(`child:${value}`)
    | AskReverse(value) => Response.later(Runtime.sendMessage(runtime, Reverse(value)))
    | AskDelayedReverse(value) =>
      Response.later(Runtime.sendMessage(runtime, DelayedReverse(value)))
    | Notice(value) => {
        lastNotice := Some(value)
        Response.none
      }
    | GetNotice => Response.now(lastNotice.contents)
    | Fail => JsError.throwWithMessage("Child handler failed")
    | Never => Response.none
    | Cancellable => {
        cancellationStartCount := cancellationStartCount.contents + 1
        switch signal {
        | Some(signal) =>
          AbortSignal.addEventListener(signal, "abort", () => {
            cancellationCount := cancellationCount.contents + 1
          })
        | None => ()
        }
        Response.later(Promise.make((_resolve, _reject) => ()))
      }
    | GetCancellationCount => Response.now(cancellationCount.contents)
    | GetCancellationStartCount => Response.now(cancellationStartCount.contents)
    | Uncloneable(_) => Response.now("unexpected")
    | _ => Response.none
    }
  }

Runtime.OnMessage.addListener(runtime, handler)
Runtime.onOpen(runtime, () => Runtime.cast(runtime, Notice("child-open")))->ignore
WindowTransport.Child.listen(transport)->Result.getOrThrow

let api: Dict.t<Obj.t> = Dict.make()
api->Dict.set(
  "invalidOrigin",
  Obj.magic(origin => {
    let invalidTransport = WindowTransport.Child.make({
      parentWindow: parentWindow(currentWindow),
      parentOrigin: origin,
      requestTimeoutMs: 500,
      maxMessageBytes: 2_000_000,
      maxPendingRequests: 100,
      maxChunkBytes: 100_000,
    })
    switch WindowTransport.Child.listen(invalidTransport) {
    | Ok() => "resolved"
    | Error(message) => message
    }
  }),
)
(Obj.magic(currentWindow): Dict.t<Obj.t>)->Dict.set("reworkerChildTest", api->Obj.magic)
