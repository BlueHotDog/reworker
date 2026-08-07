/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type messageListener = (Obj.t, unit) => unit

let leftMessageListeners: ref<array<messageListener>> = ref([])
let rightMessageListeners: ref<array<messageListener>> = ref([])
let leftCloseListeners: ref<array<string => unit>> = ref([])
let rightCloseListeners: ref<array<string => unit>> = ref([])
let leftOpen = ref(true)
let rightOpen = ref(true)

let removeListener = (listeners, listener) => {
  let removed = ref(false)
  listeners :=
    listeners.contents->Array.filter(existing => {
      if !removed.contents && existing === listener {
        removed := true
        false
      } else {
        true
      }
    })
}

let closeEndpoints = reason => {
  if leftOpen.contents || rightOpen.contents {
    leftOpen := false
    rightOpen := false
    leftCloseListeners.contents->Array.forEach(listener => listener(reason))
    rightCloseListeners.contents->Array.forEach(listener => listener(reason))
  }
}

module LeftBindings = {
  type sender = unit
  let requestTimeoutMs = 30
  let failNextPost = ref(None)

  let postMessage = message => {
    switch failNextPost.contents {
    | Some(error) => {
        failNextPost := None
        Error(error)
      }
    | None if !leftOpen.contents => Error("Endpoint is closed")
    | None => {
        rightMessageListeners.contents->Array.forEach(listener => listener(Obj.magic(message), ()))
        Ok()
      }
    }
  }

  module OnMessage = {
    let addListener = listener => {
      leftMessageListeners := leftMessageListeners.contents->Array.concat([Obj.magic(listener)])
    }
    let removeListener = listener => {
      removeListener(leftMessageListeners, Obj.magic(listener))
    }
  }

  module OnClose = {
    let addListener = listener => {
      leftCloseListeners := leftCloseListeners.contents->Array.concat([listener])
    }
  }

  let isOpen = () => leftOpen.contents
  let close = () => closeEndpoints("Endpoint closed")
}

module RightBindings = {
  type sender = unit
  let requestTimeoutMs = 30

  let postMessage = message => {
    if rightOpen.contents {
      leftMessageListeners.contents->Array.forEach(listener => listener(Obj.magic(message), ()))
      Ok()
    } else {
      Error("Endpoint is closed")
    }
  }

  module OnMessage = {
    let addListener = listener => {
      rightMessageListeners := rightMessageListeners.contents->Array.concat([Obj.magic(listener)])
    }
    let removeListener = listener => {
      removeListener(rightMessageListeners, Obj.magic(listener))
    }
  }

  module OnClose = {
    let addListener = listener => {
      rightCloseListeners := rightCloseListeners.contents->Array.concat([listener])
    }
  }

  let isOpen = () => rightOpen.contents
  let close = () => closeEndpoints("Endpoint closed")
}

type Types.message<_> +=
  | Echo(string): Types.message<string>
  | AsyncEcho(string): Types.message<string>
  | FailNow: Types.message<string>
  | FailLater: Types.message<string>
  | NeverRespond: Types.message<string>
  | Notice(string): Types.message<unit>

module LeftRuntime = Runtime.Make(LeftBindings)
module RightRuntime = Runtime.Make(RightBindings)

let receivedNotices = ref([])

let rightHandler:
  type response. (Types.message<response>, unit) => Response.t<response> =
  (message, _sender) => {
    switch message {
    | Echo(value) => Response.now(value)
    | AsyncEcho(value) => Response.later(Promise.resolve(value))
    | FailNow => JsError.throwWithMessage("Immediate handler failure")
    | FailLater =>
      Response.later(
        Promise.make((_resolve, reject) => {
          reject(JsError.make("Deferred handler failure"))
        }),
      )
    | NeverRespond => Response.none
    | Notice(value) => {
        receivedNotices := receivedNotices.contents->Array.concat([value])
        Response.none
      }
    | _ => Response.none
    }
  }

RightRuntime.OnMessage.addListener(rightHandler)
LeftRuntime.OnMessage.addListener(rightHandler)

@val external errorToString: 'a => string = "String"

let expectRejection = async (promise, expectedMessage) => {
  try {
    (await promise)->ignore
    false
  } catch {
  | error =>
    error
    ->JsExn.fromException
    ->Option.flatMap(JsExn.message)
    ->Option.getOr(errorToString(error))
    ->String.includes(expectedMessage)
  }
}

let testRoundTrip = async () => {
  let response = await LeftRuntime.sendMessage(Echo("hello"))
  response === "hello"
}

let testAsyncRoundTrip = async () => {
  let response = await LeftRuntime.sendMessage(AsyncEcho("later"))
  response === "later"
}

let testReverseRoundTrip = async () => {
  let response = await RightRuntime.sendMessage(Echo("reverse"))
  response === "reverse"
}

let testCast = () => {
  LeftRuntime.cast(Notice("received"))
  receivedNotices.contents->Array.some(value => value === "received")
}

let testImmediateRemoteError = async () => {
  await expectRejection(LeftRuntime.sendMessage(FailNow), "Immediate handler failure")
}

let testDeferredRemoteError = async () => {
  await expectRejection(LeftRuntime.sendMessage(FailLater), "Deferred handler failure")
}

let testTimeout = async () => {
  await expectRejection(LeftRuntime.sendMessage(NeverRespond), "Request timed out")
}

let testPostFailure = async () => {
  LeftBindings.failNextPost := Some("Structured clone failed")
  await expectRejection(LeftRuntime.sendMessage(Echo("uncloneable")), "Structured clone failed")
}

let testChunkedRoundTrip = async () => {
  let value = "A"->String.repeat(MessageChunker.defaultChunkSize + 1000)
  let response = await LeftRuntime.sendMessage(Echo(value))
  response === value
}

let testListenerRemoval = () => {
  let handler = (message, _sender) => {
    switch message {
    | Echo(value) => Response.now(value)
    | _ => Response.none
    }
  }
  let before = leftMessageListeners.contents->Array.length
  LeftRuntime.OnMessage.addListener(handler)
  LeftRuntime.OnMessage.removeListener(handler)
  leftMessageListeners.contents->Array.length === before
}

let testContextValidity = () => LeftRuntime.isContextValid()

let testCloseRejectsPending = async () => {
  let pending = LeftRuntime.sendMessage(NeverRespond)
  LeftRuntime.close()
  let rejected = await expectRejection(pending, "Runtime closed")
  rejected && !LeftRuntime.isContextValid() && !RightRuntime.isContextValid()
}

let runTests = async () => {
  let syncTests = [
    ("typed fire-and-forget cast", testCast),
    ("listener removal", testListenerRemoval),
    ("context validity", testContextValidity),
  ]
  let asyncTests = [
    ("typed request round trip", testRoundTrip),
    ("reverse request round trip", testReverseRoundTrip),
    ("deferred response round trip", testAsyncRoundTrip),
    ("immediate remote error", testImmediateRemoteError),
    ("deferred remote error", testDeferredRemoteError),
    ("request timeout", testTimeout),
    ("structured clone failure", testPostFailure),
    ("chunked request round trip", testChunkedRoundTrip),
    ("close rejects pending requests", testCloseRejectsPending),
  ]

  await TestUtils.runMixedTests("Runtime Integration Tests", syncTests, asyncTests)
}

let main = runTests
