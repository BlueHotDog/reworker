/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type browserWindow
type event

@val external currentWindow: browserWindow = "window"
@get external parentWindow: browserWindow => browserWindow = "parent"
@new external makeMessageEvent: (string, Obj.t) => event = "MessageEvent"
@send external dispatchEvent: (browserWindow, event) => unit = "dispatchEvent"

open WindowTransportBrowserMessages__test

let limits = {
  Runtime.requestTimeoutMs: 500,
  maxMessageBytes: 2_000_000,
  maxPendingRequests: 100,
}

let makeTransport = channel =>
  WindowTransport.Child.make({
    parentWindow: parentWindow(currentWindow),
    parentOrigin: "http://127.0.0.1:4173",
    channel,
    maxChunkBytes: 100_000,
  })

let runtimeRef = ref(None)
let lastNotice = ref(None)
let cancellationCount = ref(0)
let cancellationStartCount = ref(0)

let handler:
  type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
  (message, _sender, context) => {
    switch message {
    | Ping(value) => Response.now(`child:${value}`)
    | AskReverse(value) =>
      Response.later(Runtime.sendMessage(runtimeRef.contents->Option.getOrThrow, Reverse(value)))
    | AskDelayedReverse(value) =>
      Response.later(
        Runtime.sendMessage(runtimeRef.contents->Option.getOrThrow, DelayedReverse(value)),
      )
    | Notice(value) => {
        lastNotice := Some(value)
        Response.none
      }
    | GetNotice => Response.now(lastNotice.contents)
    | Fail => JsError.throwWithMessage("Child handler failed")
    | Never => Response.later(Promise.make((_resolve, _reject) => ()))
    | Cancellable => {
        cancellationStartCount := cancellationStartCount.contents + 1
        switch context {
        | Runtime.Request(signal) =>
          AbortSignal.onAbort(signal, () => {
            cancellationCount := cancellationCount.contents + 1
          })->ignore
        | Runtime.Cast => ()
        }
        Response.later(Promise.make((_resolve, _reject) => ()))
      }
    | GetCancellationCount => Response.now(cancellationCount.contents)
    | GetCancellationStartCount => Response.now(cancellationStartCount.contents)
    | _ => Response.none
    }
  }

let runtime = Runtime.make(makeTransport("main"), ~limits, ~handler)
runtimeRef := Some(runtime)
Runtime.onStatus(runtime, status => {
  switch status {
  | Runtime.Open => Runtime.cast(runtime, Notice("child-open"))
  | Runtime.Connecting | Runtime.Disconnected(_) | Runtime.Closed(_) => ()
  }
})->ignore

let secondaryHandler:
  type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
  (message, _sender, _context) => {
    switch message {
    | Ping(value) => Response.now(`secondary:${value}`)
    | _ => Response.none
    }
  }

let dispatchBootstrap = (channelName, port) => {
  let eventInit: Dict.t<Obj.t> = Dict.make()
  eventInit->Dict.set(
    "data",
    Obj.magic({
      "marker": "@bluehotdog/reworker/window/v2",
      "kind": "connect",
      "channel": channelName,
    }),
  )
  eventInit->Dict.set("origin", Obj.magic("http://127.0.0.1:4173"))
  eventInit->Dict.set("source", Obj.magic(parentWindow(currentWindow)))
  eventInit->Dict.set("ports", Obj.magic([port]))
  currentWindow->dispatchEvent(makeMessageEvent("message", Obj.magic(eventInit)))
}

let testConnectionSetupFailureDisconnectsRuntime = (channelName, failingMethod) => {
  let failedRuntime = Runtime.make(makeTransport(channelName), ~limits, ~handler=secondaryHandler)
  let channel = MessageChannel.make()
  let childPort = MessageChannel.port1(channel)
  let mutablePort: Dict.t<Obj.t> = Obj.magic(childPort)
  mutablePort->Dict.set(
    failingMethod,
    Obj.magic(_value => JsError.throwWithMessage("connection setup failed")),
  )
  dispatchBootstrap(channelName, childPort)
  switch Runtime.status(failedRuntime) {
  | Runtime.Disconnected(_) => Runtime.close(failedRuntime)
  | Runtime.Connecting | Runtime.Open | Runtime.Closed(_) =>
    JsError.throwWithMessage("child connection setup failure left runtime connecting")
  }
  MessagePort.close(MessageChannel.port2(channel))
}

testConnectionSetupFailureDisconnectsRuntime("install-failure", "addEventListener")
testConnectionSetupFailureDisconnectsRuntime("ready-failure", "postMessage")

let testStaleSessionIsolation = async () => {
  let channelName = "session-isolation"
  let disconnectedCount = ref(0)
  let testRuntime = Runtime.make(makeTransport(channelName), ~limits, ~handler=secondaryHandler)
  Runtime.onStatus(testRuntime, status => {
    switch status {
    | Runtime.Disconnected(_) => disconnectedCount := disconnectedCount.contents + 1
    | Runtime.Connecting | Runtime.Open | Runtime.Closed(_) => ()
    }
  })->ignore

  let oldChannel = MessageChannel.make()
  let newChannel = MessageChannel.make()
  dispatchBootstrap(channelName, MessageChannel.port1(oldChannel))
  MessagePort.postMessage(
    MessageChannel.port2(oldChannel),
    Obj.magic({
      "kind": "close",
      "reason": "stale old port",
    }),
  )
  dispatchBootstrap(channelName, MessageChannel.port1(newChannel))
  await Promise.make((resolve, _reject) => setTimeout(resolve, 20)->ignore)

  let remainsOpen = switch Runtime.status(testRuntime) {
  | Runtime.Open => true
  | Runtime.Connecting | Runtime.Disconnected(_) | Runtime.Closed(_) => false
  }
  let passed = remainsOpen && disconnectedCount.contents === 1
  Runtime.close(testRuntime)
  MessagePort.close(MessageChannel.port2(oldChannel))
  MessagePort.close(MessageChannel.port2(newChannel))
  passed
}

let secondaryRuntime = Runtime.make(makeTransport("secondary"), ~limits, ~handler=secondaryHandler)
let reentrantRuntime = Runtime.make(makeTransport("reentrant"), ~limits, ~handler=secondaryHandler)
let staleRuntime = Runtime.make(makeTransport("stale"), ~limits, ~handler=secondaryHandler)

let api: Dict.t<Obj.t> = Dict.make()
api->Dict.set("sessionIsolation", Obj.magic(() => testStaleSessionIsolation()))
api->Dict.set(
  "invalidOrigin",
  Obj.magic(origin =>
    WindowTransport.Child.make({
      parentWindow: parentWindow(currentWindow),
      parentOrigin: origin,
      channel: "invalid",
      maxChunkBytes: 100_000,
    })->ignore
  ),
)
api->Dict.set(
  "closeAll",
  Obj.magic(() => {
    Runtime.close(runtime)
    Runtime.close(secondaryRuntime)
    Runtime.close(reentrantRuntime)
    Runtime.close(staleRuntime)
  }),
)
(Obj.magic(currentWindow): Dict.t<Obj.t>)->Dict.set("reworkerChildTest", api->Obj.magic)
