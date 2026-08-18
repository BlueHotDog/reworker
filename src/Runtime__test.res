/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type Types.message<_> +=
  | Echo(string): Types.message<string>
  | Notice(string): Types.message<unit>
  | Never: Types.message<string>
  | NeverLarge(string): Types.message<string>
  | Cancellable: Types.message<string>
  | Fail: Types.message<string>
  | Ignored: Types.message<string>
  | ThrowUnstringifiable: Types.message<string>

type endpoint = {
  prepareSession: ref<option<unit => Runtime.session<unit>>>,
  session: ref<option<Runtime.session<unit>>>,
  posts: ref<array<Obj.t>>,
  autoDeliver: ref<bool>,
  teardownCount: ref<int>,
  teardownThrows: ref<bool>,
  failPostAt: ref<option<int>>,
  mutable deliver: Obj.t => unit,
}

type pair = {
  left: Runtime.transport<unit>,
  right: Runtime.transport<unit>,
  leftEndpoint: endpoint,
  rightEndpoint: endpoint,
}

let makeEndpoint = () => {
  prepareSession: ref(None),
  session: ref(None),
  posts: ref([]),
  autoDeliver: ref(true),
  teardownCount: ref(0),
  teardownThrows: ref(false),
  failPostAt: ref(None),
  deliver: _ => (),
}

let beginEndpointSession = endpoint => {
  let prepareSession = endpoint.prepareSession.contents->Option.getOrThrow
  let session = prepareSession()
  endpoint.session := Some(session)
  session.Runtime.connecting()
  session
}

let currentSession = endpoint => endpoint.session.contents->Option.getOrThrow

let makePair = (~maxChunkBytes=64, ~rightMaxChunkBytes=maxChunkBytes, ~openOnStart=true) => {
  let leftEndpoint = makeEndpoint()
  let rightEndpoint = makeEndpoint()
  leftEndpoint.deliver = payload =>
    rightEndpoint.session.contents->Option.forEach(session => session.message(payload, ()))
  rightEndpoint.deliver = payload =>
    leftEndpoint.session.contents->Option.forEach(session => session.message(payload, ()))

  let makeTransport = (endpoint, maxChunkBytes) =>
    Runtime.makeDynamicTransport(
      ~maxChunkBytes,
      ~postMessage=payload => {
        endpoint.posts := endpoint.posts.contents->Array.concat([payload])
        if endpoint.failPostAt.contents === Some(endpoint.posts.contents->Array.length) {
          Error("post failed")
        } else {
          if endpoint.autoDeliver.contents {
            endpoint.deliver(payload)
          }
          Ok()
        }
      },
      ~start=(~prepareSession) => {
        endpoint.prepareSession := Some(prepareSession)
        let session = beginEndpointSession(endpoint)
        if openOnStart {
          session.opened()
        }
      },
      ~close=() => {
        let tornDown = ref(false)
        if !tornDown.contents {
          tornDown := true
          endpoint.teardownCount := endpoint.teardownCount.contents + 1
          endpoint.prepareSession := None
          endpoint.session := None
          if endpoint.teardownThrows.contents {
            JsError.throwWithMessage("teardown failed")
          }
        }
      },
    )

  {
    left: makeTransport(leftEndpoint, maxChunkBytes),
    right: makeTransport(rightEndpoint, rightMaxChunkBytes),
    leftEndpoint,
    rightEndpoint,
  }
}

let limits = (~timeout=25, ~maxBytes=10_000, ~maxPending=10) => {
  Runtime.requestTimeoutMs: timeout,
  maxMessageBytes: maxBytes,
  maxPendingRequests: maxPending,
}

let receivedNotices = ref([])

let handler:
  type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
  (message, _sender, _context) =>
    switch message {
    | Echo(value) => Response.now(value)
    | Notice(value) => {
        receivedNotices := receivedNotices.contents->Array.concat([value])
        Response.none
      }
    | Never => Response.later(Promise.make((_resolve, _reject) => ()))
    | NeverLarge(_) => Response.later(Promise.make((_resolve, _reject) => ()))
    | Cancellable => Response.later(Promise.make((_resolve, _reject) => ()))
    | Fail => JsError.throwWithMessage("handler failed")
    | Ignored => Response.none
    | ThrowUnstringifiable => {
        let error: Dict.t<Obj.t> = Dict.make()
        error->Dict.set("valueOf", Obj.magic(() => JsError.throwWithMessage("conversion failed")))
        error->Dict.set("toString", Obj.magic(() => JsError.throwWithMessage("conversion failed")))
        JsError.throw(Obj.magic(error))
      }
    | _ => Response.none
    }

let inertHandler = (_message, _sender, _context) => Response.none

@val external errorToString: 'a => string = "String"

let errorMessage = error =>
  error->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(errorToString(error))

let rejectsWith = async (promise, expected) => {
  try {
    (await promise)->ignore
    false
  } catch {
  | error => error->errorMessage->String.includes(expected)
  }
}

let throwsWith = (callback, expected) => {
  try {
    callback()
    false
  } catch {
  | error => error->errorMessage->String.includes(expected)
  }
}

let wait = milliseconds =>
  Promise.make((resolve, _reject) => setTimeout(resolve, milliseconds)->ignore)

let protocol = (tag, fields: array<(string, Obj.t)>) => {
  let value: Dict.t<Obj.t> = Dict.make()
  value->Dict.set("TAG", Obj.magic(tag))
  fields->Array.forEach(((key, field)) => value->Dict.set(key, field))
  Obj.magic(value)
}

let field = (payload, key) => (Obj.magic(payload): Dict.t<Obj.t>)->Dict.get(key)->Option.getOrThrow
let countPackets = (endpoint, tag) =>
  endpoint.posts.contents
  ->Array.filter(payload => {
    let packetTag: string = Obj.magic(field(payload, "TAG"))
    packetTag === tag
  })
  ->Array.length

let isClosed = state =>
  switch state {
  | Runtime.Closed("Runtime closed") => true
  | Runtime.Connecting | Runtime.Open | Runtime.Disconnected(_) | Runtime.Closed(_) => false
  }

let makeRuntimes = (~maxChunkBytes=64, ~leftLimits=limits(), ~rightLimits=limits()) => {
  let pair = makePair(~maxChunkBytes)
  let left = Runtime.make(pair.left, ~limits=leftLimits, ~handler)
  let right = Runtime.make(pair.right, ~limits=rightLimits, ~handler)
  (pair, left, right)
}

let testSimpleTransportStartsOpenAndTearsDown = () => {
  let messageListener = ref(None)
  let removeCount = ref(0)
  let receivedSynchronously = ref(false)
  let simpleHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, _context) =>
      switch message {
      | Notice("synchronous") => {
          receivedSynchronously := true
          Response.none
        }
      | _ => Response.none
      }
  let transport = Runtime.makeTransport(
    ~maxChunkBytes=64,
    ~postMessage=_ => Ok(),
    ~subscribe=(~onMessage, ~onDisconnect) => {
      messageListener := Some(onMessage)
      onDisconnect->ignore
      onMessage(protocol("Cast", [("_0", Obj.magic(Notice("synchronous")))]), ())
      () => removeCount := removeCount.contents + 1
    },
  )
  let runtime = Runtime.make(transport, ~limits=limits(), ~handler=simpleHandler)
  let startedOpen =
    Runtime.status(runtime) === Runtime.Open &&
    messageListener.contents->Option.isSome &&
    receivedSynchronously.contents
  Runtime.close(runtime)
  startedOpen && removeCount.contents === 1
}

let testOversizedProtocolIdIsIgnored = () => {
  let pair = makePair()
  let calls = ref(0)
  let countingHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, _context) => {
      calls := calls.contents + 1
      switch message {
      | Echo(value) => Response.now(value)
      | _ => Response.none
      }
    }
  let runtime = Runtime.make(pair.right, ~limits=limits(), ~handler=countingHandler)
  currentSession(pair.rightEndpoint).message(
    protocol(
      "Request",
      [("id", Obj.magic("x"->String.repeat(65))), ("message", Obj.magic(Echo("ignored")))],
    ),
    (),
  )
  Runtime.close(runtime)
  calls.contents === 0
}

let testTransportSingleConsumption = () => {
  let pair = makePair()
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let rejected = throwsWith(
    () => Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)->ignore,
    "already been consumed",
  )
  Runtime.close(runtime)
  rejected
}

let testTransportRejectsUnsafeChunkCap = () =>
  throwsWith(
    () =>
      Runtime.makeDynamicTransport(
        ~maxChunkBytes=3,
        ~postMessage=_ => Ok(),
        ~start=(~prepareSession) => prepareSession->ignore,
        ~close=() => (),
      )->ignore,
    "maxChunkBytes is invalid",
  )

let testRuntimeRejectsUnsafeMessageLimit = () => {
  let pair = makePair()
  throwsWith(
    () => Runtime.make(pair.left, ~limits=limits(~maxBytes=63), ~handler=inertHandler)->ignore,
    "Runtime limits are invalid",
  )
}

let testStartFailureConsumesTransport = () => {
  let closeCount = ref(0)
  let transport = Runtime.makeDynamicTransport(
    ~maxChunkBytes=64,
    ~postMessage=_ => Ok(),
    ~start=(~prepareSession) => {
      prepareSession->ignore
      JsError.throwWithMessage("start failed")
    },
    ~close=() => closeCount := closeCount.contents + 1,
  )
  let startFailed = throwsWith(
    () => Runtime.make(transport, ~limits=limits(), ~handler=inertHandler)->ignore,
    "start failed",
  )
  let ownershipStayedTransferred = throwsWith(
    () => Runtime.make(transport, ~limits=limits(), ~handler=inertHandler)->ignore,
    "already been consumed",
  )
  startFailed && ownershipStayedTransferred && closeCount.contents === 1
}

let testPreparedSessionIsInertUntilConnecting = () => {
  let pair = makePair()
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let prepareSession = pair.leftEndpoint.prepareSession.contents->Option.getOrThrow
  let prepared: Runtime.session<unit> = prepareSession()
  let stayedOpen = Runtime.status(runtime) === Runtime.Open
  prepared.connecting()
  let becameConnecting = Runtime.status(runtime) === Runtime.Connecting
  Runtime.close(runtime)
  stayedOpen && becameConnecting
}

let testLatestPreparedSessionWins = () => {
  let pair = makePair()
  let handled = ref(0)
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=(
    _message,
    _sender,
    _context,
  ) => {
    handled := handled.contents + 1
    Response.none
  })
  let prepareSession = pair.leftEndpoint.prepareSession.contents->Option.getOrThrow
  let older = prepareSession()
  let newer = prepareSession()
  newer.connecting()
  newer.opened()
  older.connecting()
  older.opened()
  older.message(protocol("Cast", [("_0", Obj.magic(Notice("stale")))]), ())
  let passed = Runtime.status(runtime) === Runtime.Open && handled.contents === 0
  Runtime.close(runtime)
  passed
}

let testReplacementSessionCapabilitiesAreStale = () => {
  let pair = makePair()
  pair.leftEndpoint.autoDeliver := false
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler)
  Runtime.cast(left, Notice("stale"))
  let payload = pair.leftEndpoint.posts.contents[0]->Option.getOrThrow
  let staleSession = currentSession(pair.rightEndpoint)
  let current = beginEndpointSession(pair.rightEndpoint)
  staleSession.opened()
  let staleOpenIgnored = Runtime.status(right) === Runtime.Connecting
  current.opened()
  staleSession.connecting()
  staleSession.opened()
  staleSession.message(payload, ())
  staleSession.disconnected("stale disconnect")
  let passed =
    staleOpenIgnored &&
    Runtime.status(right) === Runtime.Open &&
    !(receivedNotices.contents->Array.includes("stale"))
  Runtime.close(left)
  Runtime.close(right)
  passed
}

let testPreOpenMessageIgnored = () => {
  let pair = makePair(~openOnStart=false)
  let handled = ref(0)
  let preOpenHandler = (_message, _sender, _context) => {
    handled := handled.contents + 1
    Response.none
  }
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=preOpenHandler)
  currentSession(pair.leftEndpoint).message(
    protocol("Cast", [("_0", Obj.magic(Notice("pre-open")))]),
    (),
  )
  let ignored = handled.contents === 0 && Runtime.status(runtime) === Runtime.Connecting
  Runtime.close(runtime)
  ignored
}

let testTerminalClose = () => {
  let pair = makePair()
  pair.leftEndpoint.teardownThrows := true
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let observed = ref([])
  Runtime.onStatus(runtime, state => observed := observed.contents->Array.concat([state]))->ignore
  let staleSession = currentSession(pair.leftEndpoint)
  Runtime.close(runtime)
  staleSession.opened()
  Runtime.close(runtime)
  runtime->Runtime.status->isClosed &&
  pair.leftEndpoint.teardownCount.contents === 1 &&
  observed.contents->Array.length === 1
}

let testDuplicateOpenedDoesNotNotify = () => {
  let pair = makePair()
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let openCount = ref(0)
  Runtime.onStatus(runtime, status => {
    if status === Runtime.Open {
      openCount := openCount.contents + 1
    }
  })->ignore
  currentSession(pair.leftEndpoint).opened()
  Runtime.close(runtime)
  openCount.contents === 0
}

let testClosedRuntimeRejectsStatusSubscription = () => {
  let pair = makePair()
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let staleSession = currentSession(pair.leftEndpoint)
  Runtime.close(runtime)
  let called = ref(0)
  let unsubscribe = Runtime.onStatus(runtime, _ => called := called.contents + 1)
  staleSession.opened()
  unsubscribe()
  unsubscribe()
  called.contents === 0
}

let testStatusListenerIsolation = () => {
  let pair = makePair()
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let called = ref(0)
  Runtime.onStatus(runtime, _ => JsError.throwWithMessage("listener failed"))->ignore
  Runtime.onStatus(runtime, _ => called := called.contents + 1)->ignore
  currentSession(pair.leftEndpoint).disconnected("offline")
  Runtime.close(runtime)
  called.contents === 2 && runtime->Runtime.status->isClosed
}

let testStatusCloseReentrancySuppressesStaleOpen = () => {
  let pair = makePair()
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let laterStatuses = ref([])
  Runtime.onStatus(runtime, status => {
    if status === Runtime.Open {
      Runtime.close(runtime)
    }
  })->ignore
  Runtime.onStatus(runtime, status =>
    laterStatuses := laterStatuses.contents->Array.concat([status])
  )->ignore
  let replacement = beginEndpointSession(pair.leftEndpoint)
  replacement.opened()
  laterStatuses.contents->Array.length === 2 &&
  laterStatuses.contents[0] === Some(Runtime.Connecting) &&
  laterStatuses.contents[1]->Option.mapOr(false, isClosed)
}

let testReplacementCapabilityStaysStaleAfterConnectingClose = () => {
  let pair = makePair()
  let handled = ref(0)
  let countingHandler = (_message, _sender, _context) => {
    handled := handled.contents + 1
    Response.none
  }
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=countingHandler)
  Runtime.onStatus(runtime, status => {
    if status === Runtime.Connecting {
      Runtime.close(runtime)
    }
  })->ignore

  let staleSession = beginEndpointSession(pair.leftEndpoint)
  staleSession.opened()
  staleSession.message(protocol("Cast", [("_0", Obj.magic(Notice("stale")))]), ())
  staleSession.disconnected("stale disconnect")

  runtime->Runtime.status->isClosed &&
  handled.contents === 0 &&
  pair.leftEndpoint.teardownCount.contents === 1
}

let testDirectAndChunkedRoundTrip = async () => {
  let (pair, left, right) = makeRuntimes(~maxChunkBytes=32)
  let direct = await Runtime.sendMessage(left, Echo("small"))
  let largeValue = "x"->String.repeat(500)
  let chunked = await Runtime.sendMessage(left, Echo(largeValue))
  Runtime.cast(left, Notice("direct cast"))
  Runtime.cast(left, Notice(largeValue))
  let passed =
    direct === "small" &&
    chunked === largeValue &&
    pair.leftEndpoint.posts.contents->Array.length > 4 &&
    receivedNotices.contents->Array.includes("direct cast") &&
    receivedNotices.contents->Array.includes(largeValue)
  Runtime.close(left)
  Runtime.close(right)
  passed
}

let testChunkedRequestUsesOnePendingSlot = async () => {
  let (pair, left, right) = makeRuntimes(
    ~maxChunkBytes=24,
    ~leftLimits=limits(~timeout=15, ~maxPending=1),
  )
  let pending = Runtime.sendMessage(left, NeverLarge("x"->String.repeat(500)))
  let blocked = await rejectsWith(Runtime.sendMessage(left, Echo("blocked")), "Too many pending")
  let timedOut = await rejectsWith(pending, "timed out")
  let sentChunksAndOneCancel = pair.leftEndpoint.posts.contents->Array.length > 10
  Runtime.close(left)
  Runtime.close(right)
  blocked && timedOut && sentChunksAndOneCancel
}

let testPreAndInflightAbort = async () => {
  let pair = makePair()
  let aborted = ref(0)
  let cancellableHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, context) =>
      switch message {
      | Cancellable =>
        switch context {
        | Runtime.Request(signal) => {
            AbortSignal.onAbort(signal, () => aborted := aborted.contents + 1)->ignore
            Response.later(Promise.make((_resolve, _reject) => ()))
          }
        | Runtime.Cast => Response.none
        }
      | Echo(value) => Response.now(value)
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler=cancellableHandler)
  let preController = AbortController.make()
  preController->AbortController.abort
  let pre = await rejectsWith(
    Runtime.sendMessage(left, Echo("pre"), ~signal=preController->AbortController.signal),
    "aborted",
  )
  let controller = AbortController.make()
  let pending = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  controller->AbortController.abort
  let inflight = await rejectsWith(pending, "aborted")
  Runtime.close(left)
  Runtime.close(right)
  pre && inflight && aborted.contents === 1
}

let testWhenOpenWaitsForConnection = async () => {
  let pair = makePair(~openOnStart=false)
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let opened = ref(false)
  Runtime.whenOpen(runtime)->Promise.thenResolve(() => opened := true)->ignore
  await wait(0)
  let waited = !opened.contents
  currentSession(pair.leftEndpoint).opened()
  await Runtime.whenOpen(runtime)
  Runtime.close(runtime)
  waited && opened.contents
}

let testWhenOpenRejectsAfterClose = async () => {
  let pair = makePair(~openOnStart=false)
  let runtime = Runtime.make(pair.left, ~limits=limits(), ~handler=inertHandler)
  let opening = Runtime.whenOpen(runtime)
  Runtime.close(runtime)
  let pendingRejected = await rejectsWith(opening, "Runtime closed")
  let closedRejected = await rejectsWith(Runtime.whenOpen(runtime), "Runtime closed")
  pendingRejected && closedRejected
}

let testAbortAfterResponseDoesNotCancel = async () => {
  let pair = makePair()
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler)
  let controller = AbortController.make()
  let value = await Runtime.sendMessage(
    left,
    Echo("settled"),
    ~signal=controller->AbortController.signal,
  )
  controller->AbortController.abort
  let didNotCancel = countPackets(pair.leftEndpoint, "Cancel") === 0
  Runtime.close(left)
  Runtime.close(right)
  value === "settled" && didNotCancel
}

let testLateResponseAfterAbortStaysRejected = async () => {
  let pair = makePair()
  let resolveResponse: ref<option<string => unit>> = ref(None)
  let aborted = ref(0)
  let delayedHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, context) =>
      switch message {
      | Cancellable => {
          switch context {
          | Runtime.Request(signal) =>
            AbortSignal.onAbort(signal, () => aborted := aborted.contents + 1)->ignore
          | Runtime.Cast => ()
          }
          Response.later(Promise.make((resolve, _reject) => resolveResponse := Some(resolve)))
        }
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler=delayedHandler)
  let controller = AbortController.make()
  let pending = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  controller->AbortController.abort
  resolveResponse.contents->Option.forEach(resolve => resolve("late"))
  let rejected = await rejectsWith(pending, "aborted")
  await wait(0)
  let cancelledOnce = countPackets(pair.leftEndpoint, "Cancel") === 1
  Runtime.close(left)
  Runtime.close(right)
  rejected && cancelledOnce && aborted.contents === 1
}

let testAbortAfterTimeoutDoesNotCancelTwice = async () => {
  let pair = makePair()
  let aborted = ref(0)
  let timeoutHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, context) =>
      switch message {
      | Cancellable => {
          switch context {
          | Runtime.Request(signal) =>
            AbortSignal.onAbort(signal, () => aborted := aborted.contents + 1)->ignore
          | Runtime.Cast => ()
          }
          Response.later(Promise.make((_resolve, _reject) => ()))
        }
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(~timeout=10), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(~timeout=100), ~handler=timeoutHandler)
  let controller = AbortController.make()
  let pending = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  let timedOut = await rejectsWith(pending, "timed out")
  controller->AbortController.abort
  await wait(0)
  let cancelledOnce = countPackets(pair.leftEndpoint, "Cancel") === 1
  Runtime.close(left)
  Runtime.close(right)
  timedOut && cancelledOnce && aborted.contents === 1
}

let testAbortAfterReconnectDoesNotCancelNewSession = async () => {
  let pair = makePair()
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler)
  let controller = AbortController.make()
  let pending = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  let replacement = beginEndpointSession(pair.leftEndpoint)
  replacement.opened()
  controller->AbortController.abort
  let replaced = await rejectsWith(pending, "Connection replaced")
  let didNotCancelNewSession = countPackets(pair.leftEndpoint, "Cancel") === 0
  Runtime.close(left)
  Runtime.close(right)
  replaced && didNotCancelNewSession
}

let testBoundedInboundOperations = async () => {
  let (_pair, left, right) = makeRuntimes(~rightLimits=limits(~maxPending=1))
  let first = Runtime.sendMessage(left, Never)
  let second = await rejectsWith(Runtime.sendMessage(left, Never), "Too many pending")
  Runtime.close(left)
  let firstClosed = await rejectsWith(first, "Runtime closed")
  Runtime.close(right)
  second && firstClosed
}

let testCapacityRejectedRequestCannotLaterExecute = async () => {
  let pair = makePair(~maxChunkBytes=64)
  let echoCalls = ref(0)
  let capacityHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, _context) =>
      switch message {
      | Never => Response.later(Promise.make((_resolve, _reject) => ()))
      | Echo(value) => {
          echoCalls := echoCalls.contents + 1
          Response.now(value)
        }
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(~maxPending=1), ~handler=capacityHandler)
  let controller = AbortController.make()
  let first = Runtime.sendMessage(left, Never, ~signal=controller->AbortController.signal)
  let secondStart = pair.leftEndpoint.posts.contents->Array.length
  let second = Runtime.sendMessage(left, Echo("replay"))
  let rejectedPacket = pair.leftEndpoint.posts.contents[secondStart]->Option.getOrThrow
  let capacityRejected = await rejectsWith(second, "Too many pending requests")
  controller->AbortController.abort
  let firstRejected = await rejectsWith(first, "aborted")
  pair.leftEndpoint.deliver(rejectedPacket)
  Runtime.close(left)
  Runtime.close(right)
  capacityRejected && firstRejected && echoCalls.contents === 0
}

let testMalformedOrderedChunks = async () => {
  let pair = makePair(~maxChunkBytes=20)
  pair.leftEndpoint.autoDeliver := false
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler)
  let pending = Runtime.sendMessage(left, Echo("z"->String.repeat(200)))
  let secondChunk = pair.leftEndpoint.posts.contents[1]->Option.getOrThrow
  pair.leftEndpoint.deliver(secondChunk)
  let rejected = await rejectsWith(pending, "Malformed chunk sequence")
  Runtime.close(left)
  Runtime.close(right)
  rejected
}

let testCompletedRequestsIgnoreReplay = async () => {
  let pair = makePair(~maxChunkBytes=64)
  pair.leftEndpoint.autoDeliver := false
  let calls = ref(0)
  let countingHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, _context) =>
      switch message {
      | Echo(value) => {
          calls := calls.contents + 1
          Response.now(value)
        }
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler=countingHandler)

  let direct = Runtime.sendMessage(left, Echo("direct"))
  let directPacket = pair.leftEndpoint.posts.contents[0]->Option.getOrThrow
  pair.leftEndpoint.deliver(directPacket)
  let directResult = await direct
  pair.leftEndpoint.deliver(directPacket)

  let chunkStart = pair.leftEndpoint.posts.contents->Array.length
  let largeValue = "x"->String.repeat(200)
  let chunked = Runtime.sendMessage(left, Echo(largeValue))
  let chunkPackets =
    pair.leftEndpoint.posts.contents->Array.slice(
      ~start=chunkStart,
      ~end=pair.leftEndpoint.posts.contents->Array.length,
    )
  chunkPackets->Array.forEach(pair.leftEndpoint.deliver)
  let chunkedResult = await chunked
  chunkPackets->Array.forEach(pair.leftEndpoint.deliver)

  Runtime.close(left)
  Runtime.close(right)
  directResult === "direct" && chunkedResult === largeValue && calls.contents === 2
}

let testActiveDirectReplayKeepsOriginalRequest = async () => {
  let pair = makePair(~maxChunkBytes=64)
  pair.leftEndpoint.autoDeliver := false
  let calls = ref(0)
  let resolveResponse: ref<option<string => unit>> = ref(None)
  let delayedHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, _context) =>
      switch message {
      | Echo(_) => {
          calls := calls.contents + 1
          Response.later(Promise.make((resolve, _reject) => resolveResponse := Some(resolve)))
        }
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler=delayedHandler)
  let pending = Runtime.sendMessage(left, Echo("original"))
  let packet = pair.leftEndpoint.posts.contents[0]->Option.getOrThrow
  pair.leftEndpoint.deliver(packet)
  pair.leftEndpoint.deliver(packet)
  resolveResponse.contents->Option.forEach(resolve => resolve("original"))
  let value = await pending
  Runtime.close(left)
  Runtime.close(right)
  value === "original" && calls.contents === 1
}

let testReplayWindowEvictsOldestRequest = async () => {
  let pair = makePair(~maxChunkBytes=64)
  pair.leftEndpoint.autoDeliver := false
  let calls = ref(0)
  let countingHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, _context) =>
      switch message {
      | Echo(value) => {
          calls := calls.contents + 1
          Response.now(value)
        }
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(~maxPending=2), ~handler=countingHandler)
  let packets = []
  let send = async value => {
    let start = pair.leftEndpoint.posts.contents->Array.length
    let pending = Runtime.sendMessage(left, Echo(value))
    let packet = pair.leftEndpoint.posts.contents[start]->Option.getOrThrow
    packets->Array.push(packet)->ignore
    pair.leftEndpoint.deliver(packet)
    (await pending)->ignore
  }
  await send("one")
  await send("two")
  await send("three")
  await send("four")
  pair.leftEndpoint.deliver(packets[1]->Option.getOrThrow)
  let recentIgnored = calls.contents === 4
  pair.leftEndpoint.deliver(packets[0]->Option.getOrThrow)
  let oldestEvicted = calls.contents === 5
  Runtime.close(left)
  Runtime.close(right)
  recentIgnored && oldestEvicted
}

let testMalformedRequestCannotLaterExecute = async () => {
  let pair = makePair(~maxChunkBytes=20)
  pair.leftEndpoint.autoDeliver := false
  let calls = ref(0)
  let countingHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, _context) => {
      calls := calls.contents + 1
      switch message {
      | Echo(value) => Response.now(value)
      | _ => Response.none
      }
    }
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler=countingHandler)
  let pending = Runtime.sendMessage(left, Echo("x"->String.repeat(200)))
  let packets = pair.leftEndpoint.posts.contents->Array.copy
  pair.leftEndpoint.deliver(packets[1]->Option.getOrThrow)
  let rejected = await rejectsWith(pending, "Malformed chunk sequence")
  packets->Array.forEach(pair.leftEndpoint.deliver)
  Runtime.close(left)
  Runtime.close(right)
  rejected && calls.contents === 0
}

let testInvalidChunkDoesNotDeleteExecution = async () => {
  let pair = makePair()
  let aborted = ref(0)
  let activeHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, context) =>
      switch message {
      | Cancellable =>
        switch context {
        | Runtime.Request(signal) => {
            AbortSignal.onAbort(signal, () => aborted := aborted.contents + 1)->ignore
            Response.later(Promise.make((_resolve, _reject) => ()))
          }
        | Runtime.Cast => Response.none
        }
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(), ~handler=activeHandler)
  let controller = AbortController.make()
  let pending = Runtime.sendMessage(left, Cancellable, ~signal=controller->AbortController.signal)
  let id = field(pair.leftEndpoint.posts.contents[0]->Option.getOrThrow, "id")
  pair.leftEndpoint.deliver(
    protocol(
      "CastChunk",
      [("id", id), ("index", Obj.magic(1)), ("total", Obj.magic(2)), ("body", Obj.magic("x"))],
    ),
  )
  controller->AbortController.abort
  let rejected = await rejectsWith(pending, "aborted")
  Runtime.close(left)
  Runtime.close(right)
  rejected && aborted.contents === 1
}

let testMalformedCorrelatedResponsesRejectImmediately = async () => {
  let pair = makePair()
  pair.leftEndpoint.autoDeliver := false
  let left = Runtime.make(pair.left, ~limits=limits(~timeout=100), ~handler)
  let missingValue = Runtime.sendMessage(left, Echo("missing"))
  let firstId = field(pair.leftEndpoint.posts.contents[0]->Option.getOrThrow, "id")
  currentSession(pair.leftEndpoint).message(protocol("Success", [("id", firstId)]), ())
  let missingRejected = await rejectsWith(missingValue, "Invalid response payload")

  let secondStart = pair.leftEndpoint.posts.contents->Array.length
  let wrongFailure = Runtime.sendMessage(left, Echo("wrong failure"))
  let secondId = field(pair.leftEndpoint.posts.contents[secondStart]->Option.getOrThrow, "id")
  currentSession(pair.leftEndpoint).message(
    protocol("Failure", [("id", secondId), ("message", Obj.magic(42))]),
    (),
  )
  let failureRejected = await rejectsWith(wrongFailure, "Invalid response payload")
  Runtime.close(left)
  missingRejected && failureRejected
}

let testOversizedFailureIsInvalidResponse = async () => {
  let pair = makePair()
  pair.leftEndpoint.autoDeliver := false
  let left = Runtime.make(pair.left, ~limits=limits(~maxBytes=64), ~handler)
  let pending = Runtime.sendMessage(left, Echo("error"))
  let id = field(pair.leftEndpoint.posts.contents[0]->Option.getOrThrow, "id")
  currentSession(pair.leftEndpoint).message(
    protocol("Failure", [("id", id), ("message", Obj.magic("e"->String.repeat(65)))]),
    (),
  )
  let rejected = await rejectsWith(pending, "Invalid response payload")
  Runtime.close(left)
  rejected
}

let testConnectionReplacementCommitsBeforeAbort = async () => {
  let pair = makePair()
  let reentrant = ref(None)
  let runtimeRef: ref<option<Runtime.t<unit>>> = ref(None)
  let reentrantHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, context) =>
      switch message {
      | Cancellable =>
        switch context {
        | Runtime.Request(signal) => {
            AbortSignal.onAbort(signal, () => {
              runtimeRef.contents->Option.forEach(runtime =>
                reentrant := Some(Runtime.sendMessage(runtime, Echo("reentrant")))
              )
            })->ignore
            Response.later(Promise.make((_resolve, _reject) => ()))
          }
        | Runtime.Cast => Response.none
        }
      | Echo(value) => Response.now(value)
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(~timeout=100), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(~timeout=100), ~handler=reentrantHandler)
  runtimeRef := Some(right)
  Runtime.sendMessage(left, Cancellable)->Promise.catch(_ => Promise.resolve(""))->ignore
  let replacement = beginEndpointSession(pair.rightEndpoint)
  replacement.opened()
  let rejectedDuringReplacement = switch reentrant.contents {
  | Some(promise) => await rejectsWith(promise, "not connected")
  | None => false
  }
  Runtime.close(left)
  Runtime.close(right)
  rejectedDuringReplacement
}

let testDisconnectCommitsBeforeAbort = async () => {
  let pair = makePair()
  let reentrant = ref(None)
  let runtimeRef: ref<option<Runtime.t<unit>>> = ref(None)
  let reentrantHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, context) =>
      switch message {
      | Cancellable =>
        switch context {
        | Runtime.Request(signal) => {
            AbortSignal.onAbort(signal, () => {
              runtimeRef.contents->Option.forEach(runtime =>
                reentrant := Some(Runtime.sendMessage(runtime, Echo("dead")))
              )
            })->ignore
            Response.later(Promise.make((_resolve, _reject) => ()))
          }
        | Runtime.Cast => Response.none
        }
      | _ => Response.none
      }
  let left = Runtime.make(pair.left, ~limits=limits(~timeout=100), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(~timeout=100), ~handler=reentrantHandler)
  runtimeRef := Some(right)
  Runtime.sendMessage(left, Cancellable)->Promise.catch(_ => Promise.resolve(""))->ignore
  let postCount = pair.rightEndpoint.posts.contents->Array.length
  currentSession(pair.rightEndpoint).disconnected("offline")
  let rejected = switch reentrant.contents {
  | Some(promise) => await rejectsWith(promise, "not connected")
  | None => false
  }
  Runtime.close(left)
  Runtime.close(right)
  rejected && pair.rightEndpoint.posts.contents->Array.length === postCount
}

let testAbandonedAssemblyReleasesCapacity = async () => {
  let pair = makePair(~maxChunkBytes=20)
  pair.leftEndpoint.autoDeliver := false
  let left = Runtime.make(pair.left, ~limits=limits(~timeout=15), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(~timeout=15, ~maxPending=1), ~handler)
  let abandoned = Runtime.sendMessage(left, Echo("a"->String.repeat(200)))
  abandoned->Promise.catch(_ => Promise.resolve(""))->ignore
  let firstChunk = pair.leftEndpoint.posts.contents[0]->Option.getOrThrow
  pair.leftEndpoint.deliver(firstChunk)
  await wait(30)

  let start = pair.leftEndpoint.posts.contents->Array.length
  let second = Runtime.sendMessage(left, Echo("b"->String.repeat(200)))
  pair.leftEndpoint.posts.contents
  ->Array.slice(~start, ~end=pair.leftEndpoint.posts.contents->Array.length)
  ->Array.forEach(pair.leftEndpoint.deliver)
  let completed = (await second) === "b"->String.repeat(200)
  Runtime.close(left)
  Runtime.close(right)
  completed
}

let testInboundChunkSizeUsesReceiverLimit = async () => {
  let oversizedPair = makePair(~maxChunkBytes=64, ~rightMaxChunkBytes=16)
  let oversizedLeft = Runtime.make(oversizedPair.left, ~limits=limits(), ~handler)
  let oversizedRight = Runtime.make(oversizedPair.right, ~limits=limits(), ~handler)
  let oversized = Runtime.sendMessage(oversizedLeft, Echo("x"->String.repeat(200)))
  let oversizedRejected = await rejectsWith(oversized, "Chunk exceeds maxChunkBytes")
  let stoppedAfterRejection = oversizedPair.leftEndpoint.posts.contents->Array.length === 1
  Runtime.close(oversizedLeft)
  Runtime.close(oversizedRight)

  let smallerPair = makePair(~maxChunkBytes=8, ~rightMaxChunkBytes=16)
  let smallerLeft = Runtime.make(smallerPair.left, ~limits=limits(), ~handler)
  let smallerRight = Runtime.make(smallerPair.right, ~limits=limits(), ~handler)
  let value = "y"->String.repeat(100)
  let smallerAccepted = (await Runtime.sendMessage(smallerLeft, Echo(value))) === value
  Runtime.close(smallerLeft)
  Runtime.close(smallerRight)
  oversizedRejected && stoppedAfterRejection && smallerAccepted
}

let testEmptyChunkAndAggregateAssemblyBytes = async () => {
  let emptyPair = makePair(~maxChunkBytes=20)
  emptyPair.leftEndpoint.autoDeliver := false
  let emptyLeft = Runtime.make(emptyPair.left, ~limits=limits(), ~handler)
  let emptyRight = Runtime.make(emptyPair.right, ~limits=limits(), ~handler)
  let emptyPending = Runtime.sendMessage(emptyLeft, Echo("x"->String.repeat(100)))
  let emptyChunk: Dict.t<Obj.t> =
    emptyPair.leftEndpoint.posts.contents[0]->Option.getOrThrow->Obj.magic
  emptyChunk->Dict.set("body", Obj.magic(""))
  emptyPair.leftEndpoint.deliver(Obj.magic(emptyChunk))
  let emptyRejected = await rejectsWith(emptyPending, "Malformed chunk sequence")
  Runtime.close(emptyLeft)
  Runtime.close(emptyRight)

  let aggregatePair = makePair(~maxChunkBytes=40)
  aggregatePair.leftEndpoint.autoDeliver := false
  let aggregateLeft = Runtime.make(aggregatePair.left, ~limits=limits(~maxBytes=1000), ~handler)
  let aggregateRight = Runtime.make(
    aggregatePair.right,
    ~limits=limits(~maxBytes=64, ~maxPending=2),
    ~handler,
  )
  let first = Runtime.sendMessage(aggregateLeft, Echo("a"->String.repeat(100)))
  first->Promise.catch(_ => Promise.resolve(""))->ignore
  let secondStart = aggregatePair.leftEndpoint.posts.contents->Array.length
  let second = Runtime.sendMessage(aggregateLeft, Echo("b"->String.repeat(100)))
  aggregatePair.leftEndpoint.deliver(
    aggregatePair.leftEndpoint.posts.contents[0]->Option.getOrThrow,
  )
  aggregatePair.leftEndpoint.deliver(
    aggregatePair.leftEndpoint.posts.contents[secondStart]->Option.getOrThrow,
  )
  let aggregateRejected = await rejectsWith(second, "Chunk allocation exceeds maxMessageBytes")
  Runtime.close(aggregateLeft)
  Runtime.close(aggregateRight)
  emptyRejected && aggregateRejected
}

let testSenderChunkLimitsAndPartialFailure = async () => {
  let tinyPair = makePair(~maxChunkBytes=4)
  let tinyLeft = Runtime.make(tinyPair.left, ~limits=limits(~maxBytes=50_000), ~handler)
  let tooMany = await rejectsWith(
    Runtime.sendMessage(tinyLeft, Echo("x"->String.repeat(40_000))),
    "Too many chunks",
  )
  let allocatedNothing = tinyPair.leftEndpoint.posts.contents->Array.length === 0
  Runtime.close(tinyLeft)

  let failingPair = makePair(~maxChunkBytes=20)
  failingPair.leftEndpoint.failPostAt := Some(2)
  let failingLeft = Runtime.make(failingPair.left, ~limits=limits(), ~handler)
  let failingRight = Runtime.make(failingPair.right, ~limits=limits(), ~handler)
  let partialRejected = await rejectsWith(
    Runtime.sendMessage(failingLeft, Echo("p"->String.repeat(200))),
    "post failed",
  )
  let sentCancel = failingPair.leftEndpoint.posts.contents->Array.length === 3
  Runtime.close(failingLeft)
  Runtime.close(failingRight)
  tooMany && allocatedNothing && partialRejected && sentCancel
}

let testReceiverExecutionTimeoutAndNoResponse = async () => {
  let timedPair = makePair()
  let aborted = ref(0)
  let timeoutHandler:
    type response. (Types.message<response>, unit, Runtime.context) => Response.t<response> =
    (message, _sender, context) =>
      switch message {
      | Cancellable =>
        switch context {
        | Runtime.Request(signal) => {
            AbortSignal.onAbort(signal, () => aborted := aborted.contents + 1)->ignore
            Response.later(Promise.make((_resolve, _reject) => ()))
          }
        | Runtime.Cast => Response.none
        }
      | _ => Response.none
      }
  let timedLeft = Runtime.make(timedPair.left, ~limits=limits(~timeout=100), ~handler)
  let timedRight = Runtime.make(
    timedPair.right,
    ~limits=limits(~timeout=15),
    ~handler=timeoutHandler,
  )
  let remoteTimedOut = await rejectsWith(
    Runtime.sendMessage(timedLeft, Cancellable),
    "Request timed out",
  )
  Runtime.close(timedLeft)
  Runtime.close(timedRight)

  let noResponsePair = makePair()
  let noResponseLeft = Runtime.make(noResponsePair.left, ~limits=limits(~timeout=100), ~handler)
  let noResponseRight = Runtime.make(noResponsePair.right, ~limits=limits(), ~handler)
  let immediateFailure = await rejectsWith(
    Runtime.sendMessage(noResponseLeft, Ignored),
    "Handler did not respond",
  )
  Runtime.close(noResponseLeft)
  Runtime.close(noResponseRight)
  remoteTimedOut && aborted.contents === 1 && immediateFailure
}

let testChunkAssemblyAndExecutionShareDeadline = async () => {
  let pair = makePair(~maxChunkBytes=20)
  pair.leftEndpoint.autoDeliver := false
  let left = Runtime.make(pair.left, ~limits=limits(~timeout=300), ~handler)
  let right = Runtime.make(pair.right, ~limits=limits(~timeout=80), ~handler)
  let settled = ref(false)
  Runtime.sendMessage(left, NeverLarge("d"->String.repeat(200)))
  ->Promise.catch(_ => {
    settled := true
    Promise.resolve("")
  })
  ->ignore
  let chunks = pair.leftEndpoint.posts.contents->Array.copy
  pair.leftEndpoint.deliver(chunks[0]->Option.getOrThrow)
  await wait(50)
  chunks
  ->Array.slice(~start=1, ~end=chunks->Array.length)
  ->Array.forEach(pair.leftEndpoint.deliver)
  await wait(45)
  let usedSingleDeadline = settled.contents
  Runtime.close(left)
  Runtime.close(right)
  usedSingleDeadline
}

let testExceptionMessageIsTotal = async () => {
  let (_pair, left, right) = makeRuntimes()
  let rejected = try {
    (await Runtime.sendMessage(left, ThrowUnstringifiable))->ignore
    false
  } catch {
  | _ => true
  }
  let recovered = (await Runtime.sendMessage(left, Echo("recovered"))) === "recovered"
  Runtime.close(left)
  Runtime.close(right)
  rejected && recovered
}

let testHandlerFailureIsolation = async () => {
  let (_pair, left, right) = makeRuntimes()
  let failed = await rejectsWith(Runtime.sendMessage(left, Fail), "handler failed")
  let recovered = (await Runtime.sendMessage(left, Echo("still open"))) === "still open"
  let stayedOpen = Runtime.status(right) === Runtime.Open
  Runtime.close(left)
  Runtime.close(right)
  failed && recovered && stayedOpen
}

let testAbortSubscriptionObservesExistingAbort = () => {
  let controller = AbortController.make()
  controller->AbortController.abort
  let calls = ref(0)
  let unsubscribe = AbortSignal.onAbort(controller->AbortController.signal, () =>
    calls := calls.contents + 1
  )
  unsubscribe()
  unsubscribe()
  calls.contents === 1
}

let runTests = async () => {
  let syncTests = [
    ("transport is single consumption", testTransportSingleConsumption),
    ("simple transport starts open and tears down", testSimpleTransportStartsOpenAndTearsDown),
    ("oversized protocol ID is ignored", testOversizedProtocolIdIsIgnored),
    ("transport rejects unsafe chunk cap", testTransportRejectsUnsafeChunkCap),
    ("runtime rejects unsafe message limit", testRuntimeRejectsUnsafeMessageLimit),
    ("start failure preserves transferred ownership", testStartFailureConsumesTransport),
    (
      "prepared session stays inert until Connecting commit",
      testPreparedSessionIsInertUntilConnecting,
    ),
    ("latest prepared session owns Connecting commit", testLatestPreparedSessionWins),
    ("replacement session capabilities become stale", testReplacementSessionCapabilitiesAreStale),
    ("pre-open messages are ignored", testPreOpenMessageIgnored),
    ("close is terminal and exception-safe", testTerminalClose),
    ("duplicate open does not repeat Open status", testDuplicateOpenedDoesNotNotify),
    ("closed runtime rejects status subscriptions", testClosedRuntimeRejectsStatusSubscription),
    ("status listener failures are isolated", testStatusListenerIsolation),
    ("close reentrancy suppresses stale Open", testStatusCloseReentrancySuppressesStaleOpen),
    (
      "replacement capability stays stale after Connecting close",
      testReplacementCapabilityStaysStaleAfterConnectingClose,
    ),
    ("abort subscription observes existing abort", testAbortSubscriptionObservesExistingAbort),
  ]
  let asyncTests = [
    ("direct and chunked request/cast round trip", testDirectAndChunkedRoundTrip),
    ("chunk count uses one pending slot and timeout", testChunkedRequestUsesOnePendingSlot),
    ("pre-flight and in-flight abort", testPreAndInflightAbort),
    ("whenOpen waits for connection", testWhenOpenWaitsForConnection),
    ("whenOpen rejects after close", testWhenOpenRejectsAfterClose),
    ("abort after response does not cancel", testAbortAfterResponseDoesNotCancel),
    ("late response after abort stays rejected", testLateResponseAfterAbortStaysRejected),
    ("abort after timeout does not cancel twice", testAbortAfterTimeoutDoesNotCancelTwice),
    (
      "abort after reconnect does not cancel new session",
      testAbortAfterReconnectDoesNotCancelNewSession,
    ),
    ("inbound operation count is bounded", testBoundedInboundOperations),
    (
      "capacity-rejected request cannot later execute",
      testCapacityRejectedRequestCannotLaterExecute,
    ),
    ("chunks must arrive in exact order", testMalformedOrderedChunks),
    ("completed requests ignore direct and chunk replays", testCompletedRequestsIgnoreReplay),
    ("active direct replay keeps original request", testActiveDirectReplayKeepsOriginalRequest),
    ("replay window evicts oldest request", testReplayWindowEvictsOldestRequest),
    ("malformed request cannot later execute", testMalformedRequestCannotLaterExecute),
    ("invalid chunk cannot delete active execution", testInvalidChunkDoesNotDeleteExecution),
    (
      "malformed correlated responses reject immediately",
      testMalformedCorrelatedResponsesRejectImmediately,
    ),
    ("oversized remote failure is invalid response", testOversizedFailureIsInvalidResponse),
    ("replacement commits before abort callbacks", testConnectionReplacementCommitsBeforeAbort),
    ("disconnect commits before abort callbacks", testDisconnectCommitsBeforeAbort),
    ("abandoned assembly releases inbound capacity", testAbandonedAssemblyReleasesCapacity),
    ("receiver chunk limit allows smaller peer chunks", testInboundChunkSizeUsesReceiverLimit),
    ("empty and aggregate chunk bytes are bounded", testEmptyChunkAndAggregateAssemblyBytes),
    ("sender chunk limits and partial failure", testSenderChunkLimitsAndPartialFailure),
    (
      "receiver execution timeout and no-response failure",
      testReceiverExecutionTimeoutAndNoResponse,
    ),
    ("chunk assembly and execution share deadline", testChunkAssemblyAndExecutionShareDeadline),
    ("exception message conversion is total", testExceptionMessageIsTotal),
    ("handler failures do not close runtime", testHandlerFailureIsolation),
  ]
  await TestUtils.runMixedTests("Runtime Contract Tests", syncTests, asyncTests)
}

let main = runTests
