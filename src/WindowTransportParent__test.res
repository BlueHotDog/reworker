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

let iframe = currentDocument->getElementById("child")->Nullable.toOption->Option.getOrThrow

module Bindings = WindowTransport.Parent.Make({
  type targetWindow = browserWindow
  type loadEvent = unit
  let targetOrigin = "http://127.0.0.1:4174"
  let targetWindow = () => iframe->contentWindow
  let addLoadListener = listener => addEventListener(iframe, "load", listener)
  let removeLoadListener = listener => removeEventListener(iframe, "load", listener)
  let requestTimeoutMs = 500
})

module TestRuntime = Runtime.Make(Bindings)
open WindowTransportBrowserMessages__test

let handler:
  type response. (Types.message<response>, unit) => Response.t<response> =
  (message, _sender) => {
    switch message {
    | Reverse(value) => Response.now(`parent:${value}`)
    | _ => Response.none
    }
  }

TestRuntime.OnMessage.addListener(handler)

let api: Dict.t<Obj.t> = Dict.make()
api->Dict.set("connect", Obj.magic(Bindings.connect))
api->Dict.set("ping", Obj.magic(value => TestRuntime.sendMessage(Ping(value))))
api->Dict.set("reverse", Obj.magic(value => TestRuntime.sendMessage(AskReverse(value))))
api->Dict.set("cast", Obj.magic(value => TestRuntime.cast(Notice(value))))
api->Dict.set("notice", Obj.magic(() => TestRuntime.sendMessage(GetNotice)))
api->Dict.set("fail", Obj.magic(() => TestRuntime.sendMessage(Fail)))
api->Dict.set("timeout", Obj.magic(() => TestRuntime.sendMessage(Never)))
api->Dict.set(
  "uncloneable",
  Obj.magic(() => TestRuntime.sendMessage(Uncloneable(Obj.magic(() => ())))),
)
api->Dict.set(
  "large",
  Obj.magic(async () => {
    let value = "x"->String.repeat(MessageChunker.defaultChunkSize + 1000)
    let response = await TestRuntime.sendMessage(Ping(value))
    response === `child:${value}`
  }),
)
api->Dict.set("close", Obj.magic(TestRuntime.close))
api->Dict.set("isOpen", Obj.magic(TestRuntime.isContextValid))

(Obj.magic(currentWindow): Dict.t<Obj.t>)->Dict.set("reworkerTest", api->Obj.magic)
