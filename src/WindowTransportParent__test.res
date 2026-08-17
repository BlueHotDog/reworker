/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type browserWindow
type document
type element

@val external currentWindow: browserWindow = "window"
@val external currentDocument: document = "document"
@send external getElementById: (document, string) => Nullable.t<element> = "getElementById"
@get external contentWindow: element => browserWindow = "contentWindow"
@send external addEventListener: (element, string, unit => unit) => unit = "addEventListener"
@send external removeEventListener: (element, string, unit => unit) => unit = "removeEventListener"

open WindowTransportBrowserMessages__test

let childOpenNotices = ref(0)

let handler:
  type response. (Types.message<response>, int, option<AbortSignal.t>) => Response.t<response> =
  (message, _sender, _signal) => {
    switch message {
    | Reverse(value) => Response.now(`parent:${value}`)
    | DelayedReverse(value) =>
      Response.later(
        Promise.make((resolve, _reject) => {
          setTimeout(() => resolve(`parent:${value}`), 200)->ignore
        }),
      )
    | Notice("child-open") => {
        childOpenNotices := childOpenNotices.contents + 1
        Response.none
      }
    | _ => Response.none
    }
  }

let makeTransport = (iframe, targetOrigin, ~onAdd=() => (), ~onRemove=() => ()) => {
  WindowTransport.Parent.make({
    targetOrigin,
    targetWindow: iframe->contentWindow,
    isTargetLoaded: () => true,
    addLoadListener: listener => {
      onAdd()
      addEventListener(iframe, "load", listener)
    },
    removeLoadListener: listener => {
      onRemove()
      removeEventListener(iframe, "load", listener)
    },
    requestTimeoutMs: 500,
    maxMessageBytes: 2_000_000,
    maxPendingRequests: 100,
    maxChunkBytes: 100_000,
  })
}

let makeConnection = iframe => {
  let transport = makeTransport(iframe, "http://127.0.0.1:4174")
  let runtime = Runtime.make(transport)
  Runtime.OnMessage.addListener(runtime, handler)
  (transport, runtime)
}

let firstIframe = currentDocument->getElementById("child-a")->Nullable.toOption->Option.getOrThrow
let secondIframe = currentDocument->getElementById("child-b")->Nullable.toOption->Option.getOrThrow
let firstLoadAdds = ref(0)
let firstLoadRemoves = ref(0)
let firstTransport = makeTransport(
  firstIframe,
  "http://127.0.0.1:4174",
  ~onAdd=() => firstLoadAdds := firstLoadAdds.contents + 1,
  ~onRemove=() => firstLoadRemoves := firstLoadRemoves.contents + 1,
)
let firstRuntime = Runtime.make(firstTransport)
Runtime.OnMessage.addListener(firstRuntime, handler)
let openCount = ref(0)
let closeCount = ref(0)
let reconnectCount = ref(0)
Runtime.onOpen(firstRuntime, () => openCount := openCount.contents + 1)->ignore
Runtime.onClose(firstRuntime, _reason => closeCount := closeCount.contents + 1)->ignore
Runtime.onReconnect(firstRuntime, () => reconnectCount := reconnectCount.contents + 1)->ignore
let (secondTransport, secondRuntime) = makeConnection(secondIframe)

let api: Dict.t<Obj.t> = Dict.make()
api->Dict.set(
  "connect",
  Obj.magic(async () => {
    let first = WindowTransport.Parent.connect(firstTransport)
    let second = WindowTransport.Parent.connect(secondTransport)
    await first
    await second
  }),
)
api->Dict.set("ping", Obj.magic(value => Runtime.sendMessage(firstRuntime, Ping(value))))
api->Dict.set(
  "pingFrame",
  Obj.magic((index, value) =>
    Runtime.sendMessage(index === 0 ? firstRuntime : secondRuntime, Ping(value))
  ),
)
api->Dict.set("reverse", Obj.magic(value => Runtime.sendMessage(firstRuntime, AskReverse(value))))
api->Dict.set("cast", Obj.magic(value => Runtime.cast(firstRuntime, Notice(value))))
api->Dict.set("notice", Obj.magic(() => Runtime.sendMessage(firstRuntime, GetNotice)))
api->Dict.set("childOpenNotices", Obj.magic(() => childOpenNotices.contents))
api->Dict.set("fail", Obj.magic(() => Runtime.sendMessage(firstRuntime, Fail)))
api->Dict.set("timeout", Obj.magic(() => Runtime.sendMessage(firstRuntime, Never)))
api->Dict.set(
  "cancel",
  Obj.magic(() => {
    let controller = AbortController.make()
    let pending = Runtime.sendMessage(
      firstRuntime,
      Cancellable,
      ~signal=controller->AbortController.signal,
    )
    controller->AbortController.abort
    pending
  }),
)
api->Dict.set(
  "preCancelled",
  Obj.magic(() => {
    let controller = AbortController.make()
    controller->AbortController.abort
    Runtime.sendMessage(firstRuntime, Cancellable, ~signal=controller->AbortController.signal)
  }),
)
api->Dict.set(
  "cancellationCount",
  Obj.magic(() => Runtime.sendMessage(firstRuntime, GetCancellationCount)),
)
api->Dict.set(
  "cancellationStartCount",
  Obj.magic(() => Runtime.sendMessage(firstRuntime, GetCancellationStartCount)),
)
api->Dict.set(
  "delayedReverse",
  Obj.magic(value => Runtime.sendMessage(firstRuntime, AskDelayedReverse(value))),
)
api->Dict.set(
  "uncloneable",
  Obj.magic(() => Runtime.sendMessage(firstRuntime, Uncloneable(Obj.magic(() => ())))),
)
api->Dict.set(
  "large",
  Obj.magic(async () => {
    let value = "x"->String.repeat(101_000)
    let response = await Runtime.sendMessage(firstRuntime, Ping(value))
    response === `child:${value}`
  }),
)
api->Dict.set(
  "oversized",
  Obj.magic(() => Runtime.sendMessage(firstRuntime, Ping("x"->String.repeat(2_000_000)))),
)
api->Dict.set("close", Obj.magic(() => Runtime.close(firstRuntime)))
api->Dict.set("isOpen", Obj.magic(() => Runtime.isContextValid(firstRuntime)))
api->Dict.set(
  "lifecycleCounts",
  Obj.magic(() => [openCount.contents, closeCount.contents, reconnectCount.contents]),
)
api->Dict.set("reconnectFirst", Obj.magic(() => WindowTransport.Parent.connect(firstTransport)))
api->Dict.set(
  "firstLoadListenersRemoved",
  Obj.magic(() =>
    firstLoadAdds.contents > 0 && firstLoadAdds.contents === firstLoadRemoves.contents
  ),
)
api->Dict.set(
  "invalidOrigin",
  Obj.magic(origin => WindowTransport.Parent.connect(makeTransport(firstIframe, origin))),
)

(Obj.magic(currentWindow): Dict.t<Obj.t>)->Dict.set("reworkerTest", api->Obj.magic)
