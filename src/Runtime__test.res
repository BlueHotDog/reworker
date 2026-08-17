/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type messageListener = (Obj.t, unit) => unit

@new external makeArrayBuffer: int => Obj.t = "ArrayBuffer"
@val external objectConstructorValue: Obj.t = "Object"
@val external objectPrototypeValue: Obj.t = "Object.prototype"
@val external nullValue: Obj.t = "null"
@scope("Object") @val external setPrototypeOf: (Obj.t, Obj.t) => Obj.t = "setPrototypeOf"

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

type testEndpoint = {
  messageListeners: ref<array<messageListener>>,
  openListeners: ref<array<unit => unit>>,
  closeListeners: ref<array<string => unit>>,
  isOpen: ref<bool>,
  isCurrentSender: ref<bool>,
  postCount: ref<int>,
  lastPosted: ref<option<Obj.t>>,
  afterPost: ref<unit => unit>,
}

type transportPair = {
  left: Runtime.transport<unit, unit>,
  right: Runtime.transport<unit, unit>,
  leftEndpoint: testEndpoint,
  rightEndpoint: testEndpoint,
  openEndpoints: unit => unit,
  closeEndpoints: string => unit,
}

let makeTransportPair = (
  ~initiallyOpen=true,
  ~maxMessageBytes=32_000_000,
  ~maxPendingRequests=100,
  ~receiverMaxPendingRequests=maxPendingRequests,
  ~maxChunkBytes=1_000_000,
) => {
  let leftEndpoint = {
    messageListeners: ref([]),
    openListeners: ref([]),
    closeListeners: ref([]),
    isOpen: ref(initiallyOpen),
    isCurrentSender: ref(true),
    postCount: ref(0),
    lastPosted: ref(None),
    afterPost: ref(() => ()),
  }
  let rightEndpoint = {
    messageListeners: ref([]),
    openListeners: ref([]),
    closeListeners: ref([]),
    isOpen: ref(initiallyOpen),
    isCurrentSender: ref(true),
    postCount: ref(0),
    lastPosted: ref(None),
    afterPost: ref(() => ()),
  }

  let openEndpoints = () => {
    if !leftEndpoint.isOpen.contents || !rightEndpoint.isOpen.contents {
      leftEndpoint.isOpen := true
      rightEndpoint.isOpen := true
      leftEndpoint.openListeners.contents->Array.forEach(listener => listener())
      rightEndpoint.openListeners.contents->Array.forEach(listener => listener())
    }
  }

  let closeEndpoints = reason => {
    if leftEndpoint.isOpen.contents || rightEndpoint.isOpen.contents {
      leftEndpoint.isOpen := false
      rightEndpoint.isOpen := false
      leftEndpoint.closeListeners.contents->Array.forEach(listener => listener(reason))
      rightEndpoint.closeListeners.contents->Array.forEach(listener => listener(reason))
    }
  }

  let makeTransport = (endpoint, peer, pendingLimit): Runtime.transport<unit, unit> => {
    requestTimeoutMs: 30,
    maxMessageBytes,
    maxPendingRequests: pendingLimit,
    maxChunkBytes,
    postMessage: message => {
      if endpoint.isOpen.contents {
        endpoint.postCount := endpoint.postCount.contents + 1
        endpoint.lastPosted := Some(message)
        peer.messageListeners.contents->Array.forEach(listener => listener(message, ()))
        endpoint.afterPost.contents()
        Ok()
      } else {
        Error("Endpoint is closed")
      }
    },
    addMessageListener: listener => {
      endpoint.messageListeners := endpoint.messageListeners.contents->Array.concat([listener])
    },
    removeMessageListener: listener => removeListener(endpoint.messageListeners, listener),
    addOpenListener: listener => {
      endpoint.openListeners := endpoint.openListeners.contents->Array.concat([listener])
    },
    removeOpenListener: listener => removeListener(endpoint.openListeners, listener),
    addCloseListener: listener => {
      endpoint.closeListeners := endpoint.closeListeners.contents->Array.concat([listener])
    },
    removeCloseListener: listener => removeListener(endpoint.closeListeners, listener),
    isOpen: () => endpoint.isOpen.contents,
    isCurrentSender: _ => endpoint.isOpen.contents && endpoint.isCurrentSender.contents,
    senderKey: _ => "endpoint",
    close: () => closeEndpoints("Endpoint closed"),
    extension: (),
  }

  {
    left: makeTransport(leftEndpoint, rightEndpoint, maxPendingRequests),
    right: makeTransport(rightEndpoint, leftEndpoint, receiverMaxPendingRequests),
    leftEndpoint,
    rightEndpoint,
    openEndpoints,
    closeEndpoints,
  }
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
    let removeListener = listener => removeListener(leftCloseListeners, listener)
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
    let removeListener = listener => removeListener(rightCloseListeners, listener)
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
  | Cancellable: Types.message<string>
  | MultiHandler: Types.message<string>
  | LargeResponse(int): Types.message<string>
  | UnitResponse: Types.message<unit>
  | UncloneableResponse: Types.message<string>
  | BinaryRequest(Obj.t): Types.message<bool>
  | BinaryResponse: Types.message<string>
  | NumberEcho(float): Types.message<float>
  | Notice(string): Types.message<unit>

let leftRuntime = Runtime.make({
  requestTimeoutMs: LeftBindings.requestTimeoutMs,
  maxMessageBytes: 32_000_000,
  maxPendingRequests: 100,
  maxChunkBytes: 1_000_000,
  postMessage: message => LeftBindings.postMessage(Obj.magic(message)),
  addMessageListener: listener => LeftBindings.OnMessage.addListener(Obj.magic(listener)),
  removeMessageListener: listener => LeftBindings.OnMessage.removeListener(Obj.magic(listener)),
  addOpenListener: _ => (),
  removeOpenListener: _ => (),
  addCloseListener: LeftBindings.OnClose.addListener,
  removeCloseListener: LeftBindings.OnClose.removeListener,
  isOpen: LeftBindings.isOpen,
  isCurrentSender: _ => LeftBindings.isOpen(),
  senderKey: _ => "left",
  close: LeftBindings.close,
  extension: (),
})
let rightRuntime = Runtime.make({
  requestTimeoutMs: RightBindings.requestTimeoutMs,
  maxMessageBytes: 32_000_000,
  maxPendingRequests: 100,
  maxChunkBytes: 1_000_000,
  postMessage: message => RightBindings.postMessage(Obj.magic(message)),
  addMessageListener: listener => RightBindings.OnMessage.addListener(Obj.magic(listener)),
  removeMessageListener: listener => RightBindings.OnMessage.removeListener(Obj.magic(listener)),
  addOpenListener: _ => (),
  removeOpenListener: _ => (),
  addCloseListener: RightBindings.OnClose.addListener,
  removeCloseListener: RightBindings.OnClose.removeListener,
  isOpen: RightBindings.isOpen,
  isCurrentSender: _ => RightBindings.isOpen(),
  senderKey: _ => "right",
  close: RightBindings.close,
  extension: (),
})

let receivedNotices = ref([])

let rightHandler:
  type response. (Types.message<response>, unit, option<AbortSignal.t>) => Response.t<response> =
  (message, _sender, _signal) => {
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
    | Cancellable => Response.none
    | MultiHandler => Response.none
    | LargeResponse(size) => Response.now("r"->String.repeat(size))
    | UnitResponse => Response.now()
    | UncloneableResponse => Response.now(Obj.magic(() => ()))
    | BinaryRequest(_) => Response.now(true)
    | BinaryResponse => Response.now(Obj.magic(makeArrayBuffer(1000)))
    | NumberEcho(value) => Response.now(value)
    | Notice(value) => {
        receivedNotices := receivedNotices.contents->Array.concat([value])
        Response.none
      }
    | _ => Response.none
    }
  }

Runtime.OnMessage.addListener(rightRuntime, rightHandler)
Runtime.OnMessage.addListener(leftRuntime, rightHandler)

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

let expectThrow = (callback, expectedMessage) => {
  try {
    callback()
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
  let response = await Runtime.sendMessage(leftRuntime, Echo("hello"))
  response === "hello"
}

let testAsyncRoundTrip = async () => {
  let response = await Runtime.sendMessage(leftRuntime, AsyncEcho("later"))
  response === "later"
}

let testReverseRoundTrip = async () => {
  let response = await Runtime.sendMessage(rightRuntime, Echo("reverse"))
  response === "reverse"
}

let testCast = () => {
  Runtime.cast(leftRuntime, Notice("received"))
  receivedNotices.contents->Array.some(value => value === "received")
}

let testImmediateRemoteError = async () => {
  await expectRejection(Runtime.sendMessage(leftRuntime, FailNow), "Immediate handler failure")
}

let testDeferredRemoteError = async () => {
  await expectRejection(Runtime.sendMessage(leftRuntime, FailLater), "Deferred handler failure")
}

let testTimeout = async () => {
  await expectRejection(Runtime.sendMessage(leftRuntime, NeverRespond), "Request timed out")
}

let testPostFailure = async () => {
  LeftBindings.failNextPost := Some("Structured clone failed")
  await expectRejection(
    Runtime.sendMessage(leftRuntime, Echo("uncloneable")),
    "Structured clone failed",
  )
}

let testChunkedRoundTrip = async () => {
  let passiveHandler = (_message, _sender, _signal) => Response.none
  Runtime.OnMessage.addListener(rightRuntime, passiveHandler)
  let value = "A"->String.repeat(MessageChunker.defaultChunkSize + 1000)
  let response = await Runtime.sendMessage(leftRuntime, Echo(value))
  Runtime.OnMessage.removeListener(rightRuntime, passiveHandler)
  response === value
}

let testChunkedRoundTripWithPassiveFirst = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let passiveHandler = (_message, _sender, _signal) => Response.none
  Runtime.OnMessage.addListener(right, passiveHandler)
  Runtime.OnMessage.addListener(right, rightHandler)
  let value = "B"->String.repeat(MessageChunker.defaultChunkSize + 1000)
  let response = await Runtime.sendMessage(left, Echo(value))
  Runtime.close(left)
  Runtime.close(right)
  response === value
}

let testChunkAssembliesAreSenderScoped = () => {
  let state = RequestHandler.makeState(
    ~timeoutMs=100,
    ~maxMessageBytes=1000,
    ~maxPendingRequests=10,
    ~maxChunkBytes=5,
  )
  let chunks: array<Obj.t> = Obj.magic(
    TransportMessage.createChunks(Echo("sender scoped"), ~size=5),
  )
  let handler:
    type response. (Types.message<response>, int, option<AbortSignal.t>) => Response.t<response> =
    (message, _sender, _signal) => {
      switch message {
      | Echo(value) => Response.now(value)
      | _ => Response.none
      }
    }
  for index in 0 to chunks->Array.length - 2 {
    let chunk = chunks[index]->Option.getOrThrow
    RequestHandler.make(state, ~userHandler=handler, Obj.magic(chunk), 1, "sender-1", None)->ignore
    RequestHandler.make(state, ~userHandler=handler, Obj.magic(chunk), 2, "sender-2", None)->ignore
  }
  let finalChunk = chunks[chunks->Array.length - 1]->Option.getOrThrow
  let first: Response.t<string> = Obj.magic(
    RequestHandler.make(state, ~userHandler=handler, Obj.magic(finalChunk), 1, "sender-1", None),
  )
  let second: Response.t<string> = Obj.magic(
    RequestHandler.make(state, ~userHandler=handler, Obj.magic(finalChunk), 2, "sender-2", None),
  )
  switch first {
  | Response.RespondNow(first) =>
    switch second {
    | Response.RespondNow(second) => first === "sender scoped" && second === "sender scoped"
    | Response.RespondLater(_) | Response.NoResponse => false
    }
  | Response.RespondLater(_) | Response.NoResponse => false
  }
}

let testMalformedChunkLimits = () => {
  let state = RequestHandler.makeState(
    ~timeoutMs=100,
    ~maxMessageBytes=20,
    ~maxPendingRequests=2,
    ~maxChunkBytes=10,
  )
  let handler = (_message, _sender, _signal) => Response.none
  let messageId = Id.make()
  let first = TransportMessage.Chunk.make(~messageId, ~index=0, ~total=2, ~body="1234567890")
  let final = TransportMessage.Chunk.make(~messageId, ~index=1, ~total=2, ~body="final")
  RequestHandler.make(
    state,
    ~userHandler=handler,
    TransportMessage.IntermediateChunk(first),
    (),
    "sender",
    None,
  )->ignore
  let duplicateRejected = expectThrow(
    () =>
      RequestHandler.make(
        state,
        ~userHandler=handler,
        TransportMessage.IntermediateChunk(first),
        (),
        "sender",
        None,
      )->ignore,
    "Malformed chunk sequence",
  )
  let abandonedAssemblyCleared = expectThrow(
    () =>
      RequestHandler.make(
        state,
        ~userHandler=handler,
        TransportMessage.FinalChunk(final),
        (),
        "sender",
        None,
      )->ignore,
    "Malformed chunk sequence",
  )
  let oversized = TransportMessage.Chunk.make(
    ~messageId=Id.make(),
    ~index=0,
    ~total=1,
    ~body="x"->String.repeat(11),
  )
  let oversizedRejected = expectThrow(
    () =>
      RequestHandler.make(
        state,
        ~userHandler=handler,
        TransportMessage.FinalChunk(oversized),
        (),
        "sender",
        None,
      )->ignore,
    "maxChunkBytes",
  )
  let firstAssemblyId = Id.make()
  let secondAssemblyId = Id.make()
  let thirdAssemblyId = Id.make()
  let addAssembly = messageId =>
    RequestHandler.make(
      state,
      ~userHandler=handler,
      TransportMessage.IntermediateChunk(
        TransportMessage.Chunk.make(~messageId, ~index=0, ~total=2, ~body="1234567890"),
      ),
      (),
      "sender",
      None,
    )->ignore
  addAssembly(firstAssemblyId)
  addAssembly(secondAssemblyId)
  let assemblyLimitRejected = expectThrow(
    () => addAssembly(thirdAssemblyId),
    "Too many pending chunk assemblies",
  )
  RequestHandler.cancel(state, "sender", firstAssemblyId)
  RequestHandler.cancel(state, "sender", secondAssemblyId)

  let aggregateState = RequestHandler.makeState(
    ~timeoutMs=100,
    ~maxMessageBytes=20,
    ~maxPendingRequests=3,
    ~maxChunkBytes=8,
  )
  let aggregateFirstId = Id.make()
  let aggregateSecondId = Id.make()
  let addAggregate = (messageId, index, total) =>
    RequestHandler.make(
      aggregateState,
      ~userHandler=handler,
      TransportMessage.IntermediateChunk(
        TransportMessage.Chunk.make(~messageId, ~index, ~total, ~body="12345678"),
      ),
      (),
      "sender",
      None,
    )->ignore
  addAggregate(aggregateFirstId, 0, 3)
  addAggregate(aggregateSecondId, 0, 2)
  let aggregateLimitRejected = expectThrow(
    () => addAggregate(aggregateFirstId, 1, 3),
    "Chunk allocation exceeds maxMessageBytes",
  )
  let malformedData: Dict.t<Obj.t> = Dict.make()
  malformedData->Dict.set("messageId", Obj.magic(Id.make()))
  malformedData->Dict.set("index", Obj.magic(0.5))
  malformedData->Dict.set("total", Obj.magic(1))
  malformedData->Dict.set("body", Obj.magic("body"))
  let malformedChunk: TransportMessage.chunk = Obj.magic(malformedData)
  let malformedTypeRejected = expectThrow(
    () =>
      RequestHandler.make(
        state,
        ~userHandler=handler,
        TransportMessage.FinalChunk(malformedChunk),
        (),
        "sender",
        None,
      )->ignore,
    "Malformed chunk sequence",
  )
  duplicateRejected &&
  abandonedAssemblyCleared &&
  oversizedRejected &&
  assemblyLimitRejected &&
  aggregateLimitRejected &&
  malformedTypeRejected
}

let testListenerRemoval = () => {
  let handler = (message, _sender, _signal) => {
    switch message {
    | Echo(value) => Response.now(value)
    | _ => Response.none
    }
  }
  let before = leftMessageListeners.contents->Array.length
  Runtime.OnMessage.addListener(leftRuntime, handler)
  Runtime.OnMessage.addListener(leftRuntime, handler)
  Runtime.OnMessage.removeListener(leftRuntime, handler)
  leftMessageListeners.contents->Array.length === before
}

let testContextValidity = () => Runtime.isContextValid(leftRuntime)

let testValueRuntimeConstruction = () => {
  let transport: Runtime.transport<unit, string> = {
    requestTimeoutMs: 30,
    maxMessageBytes: 32_000_000,
    maxPendingRequests: 100,
    maxChunkBytes: 1_000_000,
    postMessage: _ => Error("Not connected"),
    addMessageListener: _ => (),
    removeMessageListener: _ => (),
    addOpenListener: _ => (),
    removeOpenListener: _ => (),
    addCloseListener: _ => (),
    removeCloseListener: _ => (),
    isOpen: () => true,
    isCurrentSender: _ => true,
    senderKey: _ => "transport",
    close: () => (),
    extension: "transport state",
  }
  let runtime = Runtime.make(transport)
  let removeOpenListener = Runtime.onOpen(runtime, () => ())
  let removeCloseListener = Runtime.onClose(runtime, _reason => ())
  let removeReconnectListener = Runtime.onReconnect(runtime, () => ())
  removeOpenListener()
  removeOpenListener()
  removeCloseListener()
  removeCloseListener()
  removeReconnectListener()
  removeReconnectListener()
  let valid = Runtime.isContextValid(runtime)
  Runtime.close(runtime)
  valid && transport.extension === "transport state"
}

let testConcurrentRuntimeIsolation = async () => {
  let firstPair = makeTransportPair()
  let secondPair = makeTransportPair()
  let firstLeft = Runtime.make(firstPair.left)
  let firstRight = Runtime.make(firstPair.right)
  let secondLeft = Runtime.make(secondPair.left)
  let secondRight = Runtime.make(secondPair.right)
  Runtime.OnMessage.addListener(firstRight, rightHandler)
  Runtime.OnMessage.addListener(secondRight, rightHandler)
  let removedHandler = (message, _sender, _signal) => {
    switch message {
    | Echo(_) => Response.now("removed handler responded")
    | _ => Response.none
    }
  }
  Runtime.OnMessage.addListener(secondRight, removedHandler)
  Runtime.OnMessage.removeListener(secondRight, removedHandler)

  let firstResponse = Runtime.sendMessage(firstLeft, Echo("first"))
  let secondResponse = Runtime.sendMessage(secondLeft, Echo("second"))
  let firstSucceeded = (await firstResponse) === "first"
  let secondSucceeded = (await secondResponse) === "second"
  Runtime.cast(secondLeft, Notice("isolated cast"))
  let castSucceeded = receivedNotices.contents->Array.some(value => value === "isolated cast")

  let abandoned = Runtime.sendMessage(firstLeft, NeverRespond)
  Runtime.close(firstLeft)
  Runtime.close(firstLeft)
  let firstClosed = await expectRejection(abandoned, "Runtime closed")
  let closedSend = await expectRejection(
    Runtime.sendMessage(firstLeft, Echo("closed")),
    "Runtime is closed",
  )
  let firstListenersRemoved =
    firstPair.leftEndpoint.messageListeners.contents->Array.length === 0 &&
      firstPair.leftEndpoint.closeListeners.contents->Array.length === 0
  let secondStayedOpen =
    (await Runtime.sendMessage(secondLeft, Echo("still open"))) === "still open"

  Runtime.close(secondLeft)
  firstSucceeded &&
  secondSucceeded &&
  castSucceeded &&
  firstClosed &&
  closedSend &&
  firstListenersRemoved &&
  secondStayedOpen
}

let testLifecycleSubscriptions = () => {
  let pair = makeTransportPair(~initiallyOpen=false)
  let runtime = Runtime.make(pair.left)
  let openCount = ref(0)
  let closeCount = ref(0)
  let reconnectCount = ref(0)
  let removedCloseCount = ref(0)
  let removeOpen = Runtime.onOpen(runtime, () => openCount := openCount.contents + 1)
  let removeClose = Runtime.onClose(runtime, _reason => closeCount := closeCount.contents + 1)
  let removeReconnect = Runtime.onReconnect(runtime, () =>
    reconnectCount := reconnectCount.contents + 1
  )
  let removeUnusedClose = Runtime.onClose(runtime, _reason =>
    removedCloseCount := removedCloseCount.contents + 1
  )
  removeUnusedClose()

  pair.openEndpoints()
  pair.openEndpoints()
  let lateOpenCount = ref(0)
  let removeLateOpen = Runtime.onOpen(runtime, () => lateOpenCount := lateOpenCount.contents + 1)
  pair.closeEndpoints("Connection lost")
  pair.openEndpoints()
  removeLateOpen()
  removeOpen()
  removeReconnect()
  Runtime.close(runtime)
  Runtime.close(runtime)
  pair.openEndpoints()
  removeClose()

  openCount.contents === 1 &&
  closeCount.contents === 2 &&
  reconnectCount.contents === 1 &&
  removedCloseCount.contents === 0 &&
  lateOpenCount.contents === 0
}

let testLifecycleListenerFailures = () => {
  let pair = makeTransportPair(~initiallyOpen=false)
  let runtime = Runtime.make(pair.left)
  let openCount = ref(0)
  let closeCount = ref(0)
  let reconnectCount = ref(0)
  Runtime.onOpen(runtime, () => JsError.throwWithMessage("open listener failed"))->ignore
  Runtime.onOpen(runtime, () => openCount := openCount.contents + 1)->ignore
  Runtime.onClose(runtime, _reason => JsError.throwWithMessage("close listener failed"))->ignore
  Runtime.onClose(runtime, _reason => closeCount := closeCount.contents + 1)->ignore
  Runtime.onReconnect(runtime, () => JsError.throwWithMessage("reconnect listener failed"))->ignore
  Runtime.onReconnect(runtime, () => reconnectCount := reconnectCount.contents + 1)->ignore

  pair.openEndpoints()
  pair.closeEndpoints("Connection lost")
  pair.openEndpoints()
  Runtime.close(runtime)

  openCount.contents === 1 &&
  closeCount.contents === 2 &&
  reconnectCount.contents === 1 &&
  pair.leftEndpoint.messageListeners.contents->Array.length === 0 &&
  pair.leftEndpoint.openListeners.contents->Array.length === 0 &&
  pair.leftEndpoint.closeListeners.contents->Array.length === 0
}

let testLifecycleCloseReentrancy = () => {
  let pair = makeTransportPair(~initiallyOpen=false)
  let runtime = Runtime.make(pair.left)
  Runtime.onClose(runtime, _reason => Runtime.close(runtime))->ignore

  pair.openEndpoints()
  pair.closeEndpoints("Connection lost")

  !Runtime.isContextValid(runtime) &&
  pair.leftEndpoint.messageListeners.contents->Array.length === 0 &&
  pair.leftEndpoint.openListeners.contents->Array.length === 0 &&
  pair.leftEndpoint.closeListeners.contents->Array.length === 0
}

let testDeferredResponseAfterClose = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)

  let pending = Runtime.sendMessage(left, AsyncEcho("late"))
  Runtime.close(right)
  let rejected = await expectRejection(pending, "Endpoint closed")
  await Promise.resolve()
  rejected
}

let testPreAbortedRequest = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let controller = AbortController.make()
  controller->AbortController.abort
  let rejected = await expectRejection(
    Runtime.sendMessage(left, Echo("cancelled"), ~signal=controller->AbortController.signal),
    "Request aborted",
  )
  Runtime.close(left)
  rejected && pair.leftEndpoint.postCount.contents === 0
}

let makeCancellableHandler = (started, aborted) => {
  let handler:
    type response. (Types.message<response>, unit, option<AbortSignal.t>) => Response.t<response> =
    (message, _sender, signal) => {
      switch message {
      | Cancellable => {
          started := started.contents + 1
          switch signal {
          | Some(signal) =>
            AbortSignal.addEventListener(signal, "abort", () => aborted := aborted.contents + 1)
          | None => ()
          }
          Response.later(Promise.make((_resolve, _reject) => ()))
        }
      | Echo(value) => Response.now(value)
      | _ => Response.none
      }
    }
  handler
}

let testInflightCancellation = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let started = ref(0)
  let aborted = ref(0)
  Runtime.OnMessage.addListener(right, makeCancellableHandler(started, aborted))
  let controller = AbortController.make()
  let pending = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  controller->AbortController.abort
  controller->AbortController.abort
  let rejected = await expectRejection(pending, "Request aborted")
  Runtime.close(left)
  Runtime.close(right)
  rejected && started.contents === 1 && aborted.contents === 1
}

let testCancelledRequestReplayIgnored = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let started = ref(0)
  let aborted = ref(0)
  let request = ref(None)
  Runtime.OnMessage.addListener(right, (message, _sender, signal) => {
    switch message {
    | Cancellable => {
        started := started.contents + 1
        signal->Option.forEach(signal =>
          AbortSignal.addEventListener(
            signal,
            "abort",
            () => {
              aborted := aborted.contents + 1
              request.contents->Option.forEach(
                request =>
                  pair.rightEndpoint.messageListeners.contents->Array.forEach(
                    listener => listener(request, ()),
                  ),
              )
            },
          )
        )
        Response.later(Promise.make((_resolve, _reject) => ()))
      }
    | _ => Response.none
    }
  })
  let controller = AbortController.make()
  let pending = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  request := pair.leftEndpoint.lastPosted.contents
  controller->AbortController.abort
  request.contents->Option.forEach(request =>
    pair.rightEndpoint.messageListeners.contents->Array.forEach(listener => listener(request, ()))
  )
  let rejected = await expectRejection(pending, "Request aborted")
  Runtime.close(left)
  Runtime.close(right)
  rejected && started.contents === 1 && aborted.contents === 1
}

let testNoResponseReplayIgnored = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let handled = ref(0)
  Runtime.OnMessage.addListener(right, (_message, _sender, _signal) => {
    handled := handled.contents + 1
    Response.none
  })
  let pending = Runtime.sendMessage(left, NeverRespond)
  let request = pair.leftEndpoint.lastPosted.contents->Option.getOrThrow
  pair.rightEndpoint.messageListeners.contents->Array.forEach(listener => listener(request, ()))
  Runtime.close(left)
  let rejected = await expectRejection(pending, "Runtime closed")
  Runtime.close(right)
  rejected && handled.contents === 1
}

let testResponseWinsAbortRace = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let started = ref(0)
  let aborted = ref(0)
  Runtime.OnMessage.addListener(right, makeCancellableHandler(started, aborted))
  let controller = AbortController.make()
  let response = Runtime.sendMessage(
    left,
    Echo("response won"),
    ~signal=controller->AbortController.signal,
  )
  controller->AbortController.abort
  let value = await response
  Runtime.close(left)
  Runtime.close(right)
  value === "response won" && aborted.contents === 0
}

let testTimeoutCancelsRemote = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let started = ref(0)
  let aborted = ref(0)
  Runtime.OnMessage.addListener(right, makeCancellableHandler(started, aborted))
  let rejected = await expectRejection(Runtime.sendMessage(left, Cancellable), "Request timed out")
  Runtime.close(left)
  Runtime.close(right)
  rejected && started.contents === 1 && aborted.contents === 1
}

let testDisconnectCancelsRemote = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let started = ref(0)
  let aborted = ref(0)
  Runtime.OnMessage.addListener(right, makeCancellableHandler(started, aborted))
  let controller = AbortController.make()
  let pending = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  pair.closeEndpoints("Connection replaced")
  controller->AbortController.abort
  let rejected = await expectRejection(pending, "Connection replaced")
  Runtime.close(left)
  Runtime.close(right)
  rejected && started.contents === 1 && aborted.contents === 1
}

let testWinningHandlerCancelsLosers = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let losingAbortCount = ref(0)
  let losingHandler:
    type response. (Types.message<response>, unit, option<AbortSignal.t>) => Response.t<response> =
    (message, _sender, signal) => {
      switch message {
      | MultiHandler => {
          switch signal {
          | Some(signal) =>
            AbortSignal.addEventListener(signal, "abort", () => losingAbortCount := 1)
          | None => ()
          }
          Response.later(Promise.make((_resolve, _reject) => ()))
        }
      | _ => Response.none
      }
    }
  let winningHandler = (message, _sender, _signal) => {
    switch message {
    | MultiHandler => Response.now("winner")
    | _ => Response.none
    }
  }
  Runtime.OnMessage.addListener(right, losingHandler)
  Runtime.OnMessage.addListener(right, winningHandler)
  let response = await Runtime.sendMessage(left, MultiHandler)
  Runtime.close(left)
  Runtime.close(right)
  response === "winner" && losingAbortCount.contents === 1
}

let testChunkCancellationBetweenParts = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  let controller = AbortController.make()
  pair.leftEndpoint.afterPost :=
    (
      () => {
        if pair.leftEndpoint.postCount.contents === 1 {
          controller->AbortController.abort
        }
      }
    )

  let value = "x"->String.repeat(MessageChunker.defaultChunkSize + 1000)
  let rejected = await expectRejection(
    Runtime.sendMessage(left, Echo(value), ~signal=controller->AbortController.signal),
    "Request aborted",
  )
  Runtime.close(left)
  Runtime.close(right)
  rejected && pair.leftEndpoint.postCount.contents === 2
}

let testMessageSizeLimit = async () => {
  let pair = makeTransportPair(~maxMessageBytes=100, ~maxChunkBytes=50)
  let left = Runtime.make(pair.left)
  let rejected = await expectRejection(
    Runtime.sendMessage(left, Echo("x"->String.repeat(200))),
    "maxMessageBytes",
  )
  Runtime.close(left)
  rejected && pair.leftEndpoint.postCount.contents === 0
}

let testResponseSizeLimit = async () => {
  let pair = makeTransportPair(~maxMessageBytes=100, ~maxChunkBytes=50)
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  let rejected = await expectRejection(
    Runtime.sendMessage(left, LargeResponse(200)),
    "Response exceeds maxMessageBytes",
  )
  Runtime.close(left)
  Runtime.close(right)
  rejected
}

let testLargeResponseRoundTrip = async () => {
  let pair = makeTransportPair(~maxMessageBytes=1000, ~maxChunkBytes=50)
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  let response = await Runtime.sendMessage(left, LargeResponse(200))
  Runtime.close(left)
  Runtime.close(right)
  response === "r"->String.repeat(200)
}

let testStaleRequestIgnored = () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let received = ref(0)
  let handler = (_message, _sender, _signal) => {
    received := received.contents + 1
    Response.none
  }
  Runtime.OnMessage.addListener(right, handler)
  pair.rightEndpoint.isCurrentSender := false
  Runtime.cast(left, Notice("stale"))
  Runtime.close(left)
  Runtime.close(right)
  received.contents === 0
}

let testMalformedProtocolIgnored = () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  let ignored = try {
    pair.rightEndpoint.messageListeners.contents->Array.forEach(listener => listener(nullValue, ()))
    true
  } catch {
  | _ => false
  }
  Runtime.close(left)
  Runtime.close(right)
  ignored
}

let testStaleResponseIgnored = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  pair.leftEndpoint.isCurrentSender := false
  let rejected = await expectRejection(
    Runtime.sendMessage(left, Echo("stale")),
    "Request timed out",
  )
  Runtime.close(left)
  Runtime.close(right)
  rejected
}

let testMissingSuccessValueRejected = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let pending = Runtime.sendMessage(left, Echo("request"))
  let request: Dict.t<Obj.t> = pair.leftEndpoint.lastPosted.contents->Option.getOrThrow->Obj.magic
  let response: Dict.t<Obj.t> = Dict.make()
  response->Dict.set("TAG", Obj.magic("Success"))
  response->Dict.set("id", request->Dict.get("id")->Option.getOrThrow)
  pair.leftEndpoint.messageListeners.contents->Array.forEach(listener =>
    listener(Obj.magic(response), ())
  )
  let rejected = await expectRejection(pending, "Invalid response payload")
  Runtime.close(left)
  rejected
}

let testUnitResponseWithinLimits = async () => {
  let pair = makeTransportPair(~maxMessageBytes=100, ~maxChunkBytes=50)
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  await Runtime.sendMessage(left, UnitResponse)
  Runtime.close(left)
  Runtime.close(right)
  true
}

let testUncloneableResponseFailure = async () => {
  let pair = makeTransportPair()
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  let rejected = await expectRejection(
    Runtime.sendMessage(left, UncloneableResponse),
    "Response could not be serialized",
  )
  Runtime.close(left)
  Runtime.close(right)
  rejected
}

let testBinaryPayloadRejection = async () => {
  let pair = makeTransportPair(~maxMessageBytes=500, ~maxChunkBytes=50)
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  let requestRejected = await expectRejection(
    Runtime.sendMessage(left, BinaryRequest(makeArrayBuffer(1000))),
    "JSON-compatible",
  )
  let responseRejected = await expectRejection(
    Runtime.sendMessage(left, BinaryResponse),
    "Response could not be serialized",
  )
  let spoofedBuffer = makeArrayBuffer(1000)
  (Obj.magic(spoofedBuffer): Dict.t<Obj.t>)->Dict.set("constructor", objectConstructorValue)
  let spoofedRejected = await expectRejection(
    Runtime.sendMessage(left, BinaryRequest(spoofedBuffer)),
    "JSON-compatible",
  )
  let prototypeSpoofedBuffer = makeArrayBuffer(1000)
  setPrototypeOf(prototypeSpoofedBuffer, objectPrototypeValue)->ignore
  let prototypeSpoofedRejected = await expectRejection(
    Runtime.sendMessage(left, BinaryRequest(prototypeSpoofedBuffer)),
    "JSON-compatible",
  )
  let nonFiniteRejected = await expectRejection(
    Runtime.sendMessage(left, NumberEcho(0.0 /. 0.0)),
    "JSON-compatible",
  )
  let shared: Dict.t<Obj.t> = Dict.make()
  shared->Dict.set("value", Obj.magic("shared"))
  let repeated: Dict.t<Obj.t> = Dict.make()
  repeated->Dict.set("before", Obj.magic(shared))
  repeated->Dict.set("after", Obj.magic(shared))
  let repeatedReferenceAccepted = await Runtime.sendMessage(
    left,
    BinaryRequest(Obj.magic(repeated)),
  )
  Runtime.close(left)
  Runtime.close(right)
  requestRejected &&
  responseRejected &&
  spoofedRejected &&
  prototypeSpoofedRejected &&
  nonFiniteRejected &&
  repeatedReferenceAccepted
}

let testPendingRequestLimit = async () => {
  let pair = makeTransportPair(~maxPendingRequests=1)
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  let first = Runtime.sendMessage(left, NeverRespond)
  let secondRejected = await expectRejection(
    Runtime.sendMessage(left, Echo("blocked")),
    "Too many pending requests",
  )
  Runtime.close(left)
  let firstRejected = await expectRejection(first, "Runtime closed")
  Runtime.close(right)
  secondRejected && firstRejected
}

let testInboundRequestLimit = async () => {
  let pair = makeTransportPair(~maxPendingRequests=10, ~receiverMaxPendingRequests=1)
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let started = ref(0)
  let aborted = ref(0)
  Runtime.OnMessage.addListener(right, makeCancellableHandler(started, aborted))
  let controller = AbortController.make()
  let first = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  let secondRejected = await expectRejection(
    Runtime.sendMessage(left, Cancellable),
    "Too many pending requests",
  )
  controller->AbortController.abort
  let firstRejected = await expectRejection(first, "Request aborted")
  Runtime.close(left)
  Runtime.close(right)
  secondRejected && firstRejected && started.contents === 1 && aborted.contents === 1
}

let testConfiguredChunkSize = async () => {
  let pair = makeTransportPair(~maxMessageBytes=10_000, ~maxChunkBytes=100)
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  Runtime.OnMessage.addListener(right, rightHandler)
  let value = "c"->String.repeat(1000)
  let response = await Runtime.sendMessage(left, Echo(value))
  Runtime.close(left)
  Runtime.close(right)
  response === value && pair.leftEndpoint.postCount.contents > 2
}

let testCastMessageSizeLimit = () => {
  let pair = makeTransportPair(~maxMessageBytes=100, ~maxChunkBytes=50)
  let runtime = Runtime.make(pair.left)
  let rejected = try {
    Runtime.cast(runtime, Echo("x"->String.repeat(200)))
    false
  } catch {
  | error =>
    error
    ->JsExn.fromException
    ->Option.flatMap(JsExn.message)
    ->Option.getOr("")
    ->String.includes("maxMessageBytes")
  }
  Runtime.close(runtime)
  rejected && pair.leftEndpoint.postCount.contents === 0
}

let testChunkedCastWithPassiveFirst = () => {
  let pair = makeTransportPair(~maxMessageBytes=10_000, ~maxChunkBytes=100)
  let left = Runtime.make(pair.left)
  let right = Runtime.make(pair.right)
  let received = ref(0)
  let passiveHandler = (_message, _sender, _signal) => Response.none
  let noticeHandler = (message, _sender, _signal) => {
    switch message {
    | Notice(_) => {
        received := received.contents + 1
        Response.none
      }
    | _ => Response.none
    }
  }
  Runtime.OnMessage.addListener(right, passiveHandler)
  Runtime.OnMessage.addListener(right, noticeHandler)
  Runtime.cast(left, Notice("n"->String.repeat(1000)))
  Runtime.close(left)
  Runtime.close(right)
  received.contents === 1
}

let testInvalidRuntimeLimits = () => {
  let tinyChunks = makeTransportPair(~maxMessageBytes=100, ~maxChunkBytes=3)
  let oversizedLimit = makeTransportPair(~maxMessageBytes=1_000_000_001, ~maxChunkBytes=100)
  let nanLimit = makeTransportPair(~maxMessageBytes=Obj.magic(0.0 /. 0.0), ~maxChunkBytes=100)
  let excessiveChunks = makeTransportPair(~maxMessageBytes=40_001, ~maxChunkBytes=4)
  expectThrow(() => Runtime.make(tinyChunks.left)->ignore, "Runtime limits are invalid") &&
  expectThrow(() => Runtime.make(oversizedLimit.left)->ignore, "Runtime limits are invalid") &&
  expectThrow(() => Runtime.make(nanLimit.left)->ignore, "Runtime limits are invalid") &&
  expectThrow(() => Runtime.make(excessiveChunks.left)->ignore, "Runtime limits are invalid")
}

let testCloseRejectsPending = async () => {
  let pending = Runtime.sendMessage(leftRuntime, NeverRespond)
  Runtime.close(leftRuntime)
  let rejected = await expectRejection(pending, "Runtime closed")
  rejected && !Runtime.isContextValid(leftRuntime) && !Runtime.isContextValid(rightRuntime)
}

let runTests = async () => {
  let syncTests = [
    ("typed fire-and-forget cast", testCast),
    ("listener removal", testListenerRemoval),
    ("context validity", testContextValidity),
    ("value runtime construction", testValueRuntimeConstruction),
    ("removable lifecycle subscriptions", testLifecycleSubscriptions),
    ("lifecycle listener failure isolation", testLifecycleListenerFailures),
    ("lifecycle close reentrancy", testLifecycleCloseReentrancy),
    ("chunk assemblies are sender scoped", testChunkAssembliesAreSenderScoped),
    ("malformed chunk limits", testMalformedChunkLimits),
    ("cast message size limit", testCastMessageSizeLimit),
    ("chunked cast with passive handler first", testChunkedCastWithPassiveFirst),
    ("stale request ignored", testStaleRequestIgnored),
    ("malformed protocol ignored", testMalformedProtocolIgnored),
    ("invalid runtime limits", testInvalidRuntimeLimits),
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
    ("chunked request with passive handler first", testChunkedRoundTripWithPassiveFirst),
    ("concurrent runtime isolation", testConcurrentRuntimeIsolation),
    ("deferred response after close", testDeferredResponseAfterClose),
    ("pre-aborted request", testPreAbortedRequest),
    ("in-flight request cancellation", testInflightCancellation),
    ("cancelled request replay ignored", testCancelledRequestReplayIgnored),
    ("no-response request replay ignored", testNoResponseReplayIgnored),
    ("response wins abort race", testResponseWinsAbortRace),
    ("timeout cancels remote handler", testTimeoutCancelsRemote),
    ("disconnect cancels remote handler", testDisconnectCancelsRemote),
    ("winning handler cancels losing handlers", testWinningHandlerCancelsLosers),
    ("chunk cancellation between parts", testChunkCancellationBetweenParts),
    ("message size limit", testMessageSizeLimit),
    ("response size limit", testResponseSizeLimit),
    ("large response round trip", testLargeResponseRoundTrip),
    ("stale response ignored", testStaleResponseIgnored),
    ("missing success value rejected", testMissingSuccessValueRejected),
    ("unit response within limits", testUnitResponseWithinLimits),
    ("uncloneable response failure", testUncloneableResponseFailure),
    ("binary payload rejection", testBinaryPayloadRejection),
    ("pending request limit", testPendingRequestLimit),
    ("inbound request limit", testInboundRequestLimit),
    ("configured chunk size", testConfiguredChunkSize),
    ("close rejects pending requests", testCloseRejectsPending),
  ]

  await TestUtils.runMixedTests("Runtime Integration Tests", syncTests, asyncTests)
}

let main = runTests
