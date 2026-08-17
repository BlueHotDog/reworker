/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type browserWindow
type document
type element
type event

@val external currentWindow: browserWindow = "window"
@val external currentDocument: document = "document"
@send external getElementById: (document, string) => Nullable.t<element> = "getElementById"
@get external contentWindow: element => browserWindow = "contentWindow"
@send external addEventListener: (element, string, unit => unit) => unit = "addEventListener"
@send external removeEventListener: (element, string, unit => unit) => unit = "removeEventListener"
@send external dispatchEvent: (element, event) => unit = "dispatchEvent"
@new external makeEvent: string => event = "Event"
@val external globalObject: Dict.t<Obj.t> = "globalThis"
@val external portListenerRemoves: int = "portListenerRemoves"

open WindowTransportBrowserMessages__test

let limits = {
  Runtime.requestTimeoutMs: 500,
  maxMessageBytes: 2_000_000,
  maxPendingRequests: 100,
}

let childOpenNotices = ref(0)

let handler:
  type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
  (message, _sender, _context) => {
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

let makeTransport = (
  iframe,
  targetOrigin,
  channel,
  ~timeout=500,
  ~onAdd=() => (),
  ~onRemove=() => (),
) =>
  WindowTransport.Parent.make({
    targetOrigin,
    targetWindow: iframe->contentWindow,
    channel,
    subscribeLoad: listener => {
      onAdd()
      addEventListener(iframe, "load", listener)
      () => {
        onRemove()
        removeEventListener(iframe, "load", listener)
      }
    },
    connectionTimeoutMs: timeout,
    maxChunkBytes: 100_000,
  })

let makeRuntime = (iframe, channel, ~timeout=500) =>
  Runtime.make(makeTransport(iframe, "http://127.0.0.1:4174", channel, ~timeout), ~limits, ~handler)

let testSubscribeFailureCleansCallbackConnection = iframe => {
  let removalsBefore = portListenerRemoves
  let rolledBackSubscription = ref(false)
  let didThrow = ref(false)
  try {
    Runtime.make(
      WindowTransport.Parent.make({
        targetWindow: iframe->contentWindow,
        targetOrigin: "http://127.0.0.1:4174",
        channel: "subscribe-failure",
        subscribeLoad: onLoad => {
          onLoad()
          // A throwing subscriber must undo registration because no disposer can be returned.
          rolledBackSubscription := true
          JsError.throwWithMessage("subscribe failed")
        },
        connectionTimeoutMs: 500,
        maxChunkBytes: 100_000,
      }),
      ~limits,
      ~handler,
    )->ignore
  } catch {
  | _ => didThrow := true
  }
  if (
    !didThrow.contents ||
    !rolledBackSubscription.contents ||
    portListenerRemoves - removalsBefore !== 2
  ) {
    JsError.throwWithMessage("subscribe failure did not roll back parent startup")
  }
}

let testInitialStartFailureRemovesLoadSubscription = iframe => {
  let originalMessageChannel = globalObject->Dict.get("MessageChannel")
  let removeCount = ref(0)
  let didThrow = ref(false)
  globalObject->Dict.set("MessageChannel", Obj.magic(undefined))
  try {
    Runtime.make(
      WindowTransport.Parent.make({
        targetWindow: iframe->contentWindow,
        targetOrigin: "http://127.0.0.1:4174",
        channel: "initial-start-failure",
        subscribeLoad: _onLoad => () => removeCount := removeCount.contents + 1,
        connectionTimeoutMs: 500,
        maxChunkBytes: 100_000,
      }),
      ~limits,
      ~handler,
    )->ignore
  } catch {
  | _ => didThrow := true
  }
  originalMessageChannel->Option.forEach(value => globalObject->Dict.set("MessageChannel", value))
  if !didThrow.contents || removeCount.contents !== 1 {
    JsError.throwWithMessage("initial start failure did not remove load subscription")
  }
}

let firstIframe = currentDocument->getElementById("child-a")->Nullable.toOption->Option.getOrThrow
let secondIframe = currentDocument->getElementById("child-b")->Nullable.toOption->Option.getOrThrow
let reentrantIframe =
  currentDocument->getElementById("child-c")->Nullable.toOption->Option.getOrThrow
let staleIframe = currentDocument->getElementById("child-d")->Nullable.toOption->Option.getOrThrow
testSubscribeFailureCleansCallbackConnection(firstIframe)
testInitialStartFailureRemovesLoadSubscription(firstIframe)
let firstLoadAdds = ref(0)
let firstLoadRemoves = ref(0)
let firstRuntime = Runtime.make(
  makeTransport(
    firstIframe,
    "http://127.0.0.1:4174",
    "main",
    ~onAdd=() => firstLoadAdds := firstLoadAdds.contents + 1,
    ~onRemove=() => firstLoadRemoves := firstLoadRemoves.contents + 1,
  ),
  ~limits,
  ~handler,
)
let secondRuntime = makeRuntime(secondIframe, "main")
let isolatedRuntime = makeRuntime(firstIframe, "secondary")
let reentrantRuntime = makeRuntime(reentrantIframe, "reentrant")
let staleRuntime = makeRuntime(staleIframe, "stale", ~timeout=100)

let openCount = ref(0)
let disconnectedCount = ref(0)
let closedCount = ref(0)
Runtime.onStatus(firstRuntime, status => {
  switch status {
  | Runtime.Open => openCount := openCount.contents + 1
  | Runtime.Disconnected(_) => disconnectedCount := disconnectedCount.contents + 1
  | Runtime.Closed(_) => closedCount := closedCount.contents + 1
  | Runtime.Connecting => ()
  }
})->ignore

let closeOnDisconnect = ref(false)
Runtime.onStatus(reentrantRuntime, status => {
  switch status {
  | Runtime.Disconnected(_) if closeOnDisconnect.contents => Runtime.close(reentrantRuntime)
  | Runtime.Connecting | Runtime.Open | Runtime.Disconnected(_) | Runtime.Closed(_) => ()
  }
})->ignore

// Simulates a load racing initial bootstrap. Real iframe load may replace this attempt again.
staleIframe->dispatchEvent(makeEvent("load"))

let isOpen = runtime => {
  switch Runtime.status(runtime) {
  | Runtime.Open => true
  | Runtime.Connecting | Runtime.Disconnected(_) | Runtime.Closed(_) => false
  }
}

let api: Dict.t<Obj.t> = Dict.make()
api->Dict.set("isOpen", Obj.magic(() => isOpen(firstRuntime)))
api->Dict.set(
  "allOpen",
  Obj.magic(() =>
    isOpen(firstRuntime) &&
    isOpen(secondRuntime) &&
    isOpen(isolatedRuntime) &&
    isOpen(reentrantRuntime)
  ),
)
api->Dict.set("staleOpen", Obj.magic(() => isOpen(staleRuntime)))
api->Dict.set("ping", Obj.magic(value => Runtime.sendMessage(firstRuntime, Ping(value))))
api->Dict.set(
  "pingFrame",
  Obj.magic((index, value) =>
    Runtime.sendMessage(index === 0 ? firstRuntime : secondRuntime, Ping(value))
  ),
)
api->Dict.set("pingIsolated", Obj.magic(value => Runtime.sendMessage(isolatedRuntime, Ping(value))))
api->Dict.set("pingStale", Obj.magic(value => Runtime.sendMessage(staleRuntime, Ping(value))))
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
api->Dict.set(
  "close",
  Obj.magic(() => {
    Runtime.close(firstRuntime)
    Runtime.close(firstRuntime)
  }),
)
api->Dict.set(
  "lifecycleCounts",
  Obj.magic(() => [openCount.contents, disconnectedCount.contents, closedCount.contents]),
)
api->Dict.set(
  "closeDuringReplacement",
  Obj.magic(() => {
    closeOnDisconnect := true
    reentrantIframe->dispatchEvent(makeEvent("load"))
    switch Runtime.status(reentrantRuntime) {
    | Runtime.Closed(_) => true
    | Runtime.Connecting | Runtime.Open | Runtime.Disconnected(_) => false
    }
  }),
)
api->Dict.set(
  "firstLoadListenersRemoved",
  Obj.magic(() =>
    firstLoadAdds.contents === 1 && firstLoadAdds.contents === firstLoadRemoves.contents
  ),
)
api->Dict.set(
  "invalidOrigin",
  Obj.magic(origin => makeTransport(firstIframe, origin, "invalid")->ignore),
)
api->Dict.set(
  "invalidChannel",
  Obj.magic(() => makeTransport(firstIframe, "http://127.0.0.1:4174", "")->ignore),
)

(Obj.magic(currentWindow): Dict.t<Obj.t>)->Dict.set("reworkerTest", api->Obj.magic)
