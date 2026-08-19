/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type session<'sender> = {
  connecting: unit => unit,
  opened: unit => unit,
  message: (Obj.t, 'sender) => unit,
  disconnected: string => unit,
}

type transport<'sender> = {
  postMessage: Obj.t => result<unit, string>,
  start: (~prepareSession: unit => session<'sender>) => unit,
  close: unit => unit,
  maxChunkBytes: int,
  consumed: ref<bool>,
}

type limits = {
  requestTimeoutMs: int,
  maxMessageBytes: int,
  maxPendingRequests: int,
}

type context = Request(AbortSignal.t) | Cast
type status = Connecting | Open | Disconnected(string) | Closed(string)
type sessionToken = ref<unit>
type lifecycle =
  | LifecycleConnecting(option<sessionToken>)
  | LifecycleOpen(sessionToken)
  | LifecycleDisconnected(string)
  | LifecycleClosed(string)

type protocolMessage =
  | Request({id: Id.t, message: Obj.t})
  | RequestChunk({id: Id.t, index: int, total: int, body: string})
  | Cast(Obj.t)
  | CastChunk({id: Id.t, index: int, total: int, body: string})
  | Cancel(Id.t)
  | Success({id: Id.t, value: Obj.t})
  | Failure({id: Id.t, message: string})

type reply = ReplyValue(Obj.t) | ReplyError(string)
type payloadIssue = OversizedPayload | InvalidPayload
type outgoingChunks = RequestChunks | CastChunks

type pendingRequest = {
  resolve: Obj.t => unit,
  reject: JsError.t => unit,
  timeoutId: timeoutId,
  removeAbortListener: unit => unit,
}

type operationKind = RequestOperation(sessionToken) | CastOperation
type assembly = {
  total: int,
  mutable bytes: int,
  body: array<string>,
}
type operationPhase = Assembling(assembly) | Executing(AbortController.t)
type operation = {
  kind: operationKind,
  mutable phase: operationPhase,
  timeoutId: timeoutId,
}

type registeredHandler<'sender> = (Obj.t, 'sender, context) => Response.t<Obj.t>

type t<'sender> = {
  transport: transport<'sender>,
  limits: limits,
  handler: registeredHandler<'sender>,
  pending: Map.t<Id.t, pendingRequest>,
  operations: Map.t<Id.t, operation>,
  settled: Map.t<Id.t, unit>,
  statusListeners: ref<array<status => unit>>,
  latestPreparedSessionToken: ref<option<sessionToken>>,
  lifecycle: ref<lifecycle>,
  assemblyBytes: ref<int>,
}

@scope("Number") @val external isSafeInteger: Obj.t => bool = "isSafeInteger"
@scope("Object") @val external hasOwn: (Obj.t, string) => bool = "hasOwn"
@val external errorToString: 'a => string = "String"

let exceptionMessage = error => {
  try {
    switch error->JsExn.fromException->Option.flatMap(JsExn.message) {
    | Some(message) => message
    | None => errorToString(error)
    }
  } catch {
  | _ => "Unknown error"
  }
}

let makeDynamicTransport = (~postMessage, ~start, ~close, ~maxChunkBytes) => {
  if !isSafeInteger(Obj.magic(maxChunkBytes)) || maxChunkBytes < 4 {
    JsError.throwWithMessage("Transport maxChunkBytes is invalid")
  }
  {postMessage, start, close, maxChunkBytes, consumed: ref(false)}
}

let makeTransport = (~postMessage, ~subscribe, ~maxChunkBytes) => {
  let teardown = ref(None)
  makeDynamicTransport(
    ~postMessage,
    ~maxChunkBytes,
    ~start=(~prepareSession) => {
      let session = prepareSession()
      session.connecting()
      session.opened()
      teardown := Some(subscribe(~onMessage=session.message, ~onDisconnect=session.disconnected))
    },
    ~close=() => {
      let current = teardown.contents
      teardown := None
      current->Option.forEach(dispose => dispose())
    },
  )
}

let rejectedPromise = message => Promise.make((_resolve, reject) => reject(JsError.make(message)))

let normalizePayload = (runtime, value) => {
  try {
    switch value->MessageChunker.prepareJsonWithin(~maxBytes=runtime.limits.maxMessageBytes) {
    | Some({value, _}) => Ok(value)
    | None => Error(OversizedPayload)
    }
  } catch {
  | _ => Error(InvalidPayload)
  }
}

let lifecycleStatus = lifecycle =>
  switch lifecycle {
  | LifecycleConnecting(_) => Connecting
  | LifecycleOpen(_) => Open
  | LifecycleDisconnected(reason) => Disconnected(reason)
  | LifecycleClosed(reason) => Closed(reason)
  }

let notifyStatus = (runtime, committedLifecycle) => {
  let committedStatus = lifecycleStatus(committedLifecycle)
  runtime.statusListeners.contents->Array.forEach(listener => {
    if runtime.lifecycle.contents === committedLifecycle {
      try {
        listener(committedStatus)
      } catch {
      | error => Console.error2("Status listener failed:", error)
      }
    }
  })
}

let status = runtime => lifecycleStatus(runtime.lifecycle.contents)

let onStatus = (runtime, listener) => {
  switch runtime.lifecycle.contents {
  | LifecycleClosed(_) => () => ()
  | LifecycleConnecting(_) | LifecycleOpen(_) | LifecycleDisconnected(_) => {
      let subscription = status => listener(status)
      runtime.statusListeners := runtime.statusListeners.contents->Array.concat([subscription])
      let subscribed = ref(true)
      () => {
        if subscribed.contents {
          subscribed := false
          runtime.statusListeners :=
            runtime.statusListeners.contents->Array.filter(existing => existing !== subscription)
        }
      }
    }
  }
}

let markSettled = (runtime, id) => {
  if !(runtime.settled->Map.has(id)) {
    let capacity = runtime.limits.maxPendingRequests + 1
    if runtime.settled->Map.size >= capacity {
      let oldest = runtime.settled->Map.keys->Iterator.next
      oldest.Iterator.value->Option.forEach(oldest => runtime.settled->Map.delete(oldest)->ignore)
    }
    runtime.settled->Map.set(id, ())
  }
}

let sendProtocol = (runtime, sessionToken, message) => {
  switch runtime.lifecycle.contents {
  | LifecycleClosed(_) => JsError.throwWithMessage("Runtime is closed")
  | LifecycleConnecting(_) | LifecycleDisconnected(_) =>
    JsError.throwWithMessage("Runtime is not connected")
  | LifecycleOpen(current) if current === sessionToken =>
    switch runtime.transport.postMessage(Obj.magic(message)) {
    | Ok() => ()
    | Error(message) => JsError.throwWithMessage(message)
    }
  | LifecycleOpen(_) => JsError.throwWithMessage("Runtime is not connected")
  }
}

let sendCancel = (runtime, sessionToken, id) => {
  try {
    sendProtocol(runtime, sessionToken, Cancel(id))
  } catch {
  | _ => ()
  }
}

let sendChunks = (runtime, sessionToken, id, chunks, kind) => {
  let index = ref(0)
  try {
    while (
      index.contents < chunks->Array.length &&
        switch kind {
        | RequestChunks => runtime.pending->Map.has(id)
        | CastChunks => true
        }
    ) {
      let body = chunks[index.contents]->Option.getOrThrow
      let message: protocolMessage = switch kind {
      | RequestChunks =>
        RequestChunk({id, index: index.contents, total: chunks->Array.length, body})
      | CastChunks => CastChunk({id, index: index.contents, total: chunks->Array.length, body})
      }
      sendProtocol(runtime, sessionToken, message)
      index := index.contents + 1
    }
  } catch {
  | error => {
      if index.contents > 0 {
        sendCancel(runtime, sessionToken, id)
      }
      JsError.throw(Obj.magic(error))
    }
  }
}

let takePending = (runtime, id) => {
  switch runtime.pending->Map.get(id) {
  | Some(pending) => {
      runtime.pending->Map.delete(id)->ignore
      clearTimeout(pending.timeoutId)
      pending.removeAbortListener()
      Some(pending)
    }
  | None => None
  }
}

let rejectPending = (runtime, id, message, ~cancelSession=?) => {
  switch takePending(runtime, id) {
  | Some(pending) => {
      pending.reject(JsError.make(message))
      switch cancelSession {
      | Some(sessionToken) => sendCancel(runtime, sessionToken, id)
      | None => ()
      }
    }
  | None => ()
  }
}

let removeOperation = (runtime, id, expected, ~abort) => {
  switch runtime.operations->Map.get(id) {
  | Some(operation) if operation === expected => {
      clearTimeout(operation.timeoutId)
      runtime.operations->Map.delete(id)->ignore
      markSettled(runtime, id)
      switch operation.phase {
      | Assembling(assembly) =>
        runtime.assemblyBytes := runtime.assemblyBytes.contents - assembly.bytes
      | Executing(controller) if abort => controller->AbortController.abort
      | Executing(_) => ()
      }
      true
    }
  | Some(_) | None => false
  }
}

let whenOpen = runtime =>
  switch runtime.lifecycle.contents {
  | LifecycleOpen(_) => Promise.resolve()
  | LifecycleClosed(reason) => rejectedPromise(reason)
  | LifecycleConnecting(_) | LifecycleDisconnected(_) =>
    Promise.make((resolve, reject) => {
      let unsubscribe = ref(() => ())
      unsubscribe :=
        onStatus(runtime, status => {
          switch status {
          | Open => {
              unsubscribe.contents()
              resolve()
            }
          | Closed(reason) => {
              unsubscribe.contents()
              reject(JsError.make(reason))
            }
          | Connecting | Disconnected(_) => ()
          }
        })
    })
  }

let clearCurrentWork = (runtime, reason) => {
  let pendingRequests = []
  runtime.pending->Map.forEach(pending => pendingRequests->Array.push(pending)->ignore)
  let operations = []
  runtime.operations->Map.forEach(operation => operations->Array.push(operation)->ignore)
  runtime.pending->Map.clear
  runtime.operations->Map.clear
  runtime.assemblyBytes := 0
  runtime.settled->Map.clear
  pendingRequests->Array.forEach(pending => {
    clearTimeout(pending.timeoutId)
    pending.removeAbortListener()
    pending.reject(JsError.make(reason))
  })
  operations->Array.forEach(operation => {
    clearTimeout(operation.timeoutId)
    switch operation.phase {
    | Executing(controller) => controller->AbortController.abort
    | Assembling(_) => ()
    }
  })
}

let sendReply = (runtime, sessionToken, id, reply) => {
  switch runtime.lifecycle.contents {
  | LifecycleOpen(current) if current === sessionToken => {
      let (bounded, retryClone): (protocolMessage, bool) = switch reply {
      | ReplyValue(value) =>
        try {
          switch value->MessageChunker.prepareJsonWithin(~maxBytes=runtime.limits.maxMessageBytes) {
          | Some(prepared) => (Success({id, value: prepared.value}), true)
          | None => (Failure({id, message: "Response exceeds maxMessageBytes"}), false)
          }
        } catch {
        | _ => (Failure({id, message: "Response could not be serialized"}), false)
        }
      | ReplyError(message) => (
          Failure({
            id,
            message: message->MessageChunker.stringByteLength > runtime.limits.maxMessageBytes
              ? "Remote error exceeds maxMessageBytes"
              : message,
          }),
          false,
        )
      }
      try {
        sendProtocol(runtime, sessionToken, bounded)
      } catch {
      | _ =>
        if retryClone {
          try {
            sendProtocol(
              runtime,
              sessionToken,
              (Failure({id, message: "Response could not be cloned"}): protocolMessage),
            )
          } catch {
          | _ => ()
          }
        }
      }
    }
  | LifecycleConnecting(_) | LifecycleOpen(_) | LifecycleDisconnected(_) | LifecycleClosed(_) => ()
  }
}

let executeRequest = (runtime, sessionToken, id, message, sender, operation, controller) => {
  let complete = makeResponse => {
    if removeOperation(runtime, id, operation, ~abort=false) {
      sendReply(runtime, sessionToken, id, makeResponse())
    }
  }
  try {
    switch runtime.handler(message, sender, Request(controller->AbortController.signal)) {
    | Response.RespondNow(value) => complete(() => ReplyValue(value))
    | Response.RespondLater(promise) =>
      promise
      ->Promise.thenResolve(value => {
        complete(() => ReplyValue(value))
      })
      ->Promise.catch(error => {
        complete(() => ReplyError(exceptionMessage(error)))
        Promise.resolve()
      })
      ->ignore
    | Response.NoResponse => complete(() => ReplyError("Handler did not respond"))
    }
  } catch {
  | error => complete(() => ReplyError(exceptionMessage(error)))
  }
}

let startOperation = (runtime, id, kind, phase) => {
  let operationRef: ref<option<operation>> = ref(None)
  let timeoutId = setTimeout(() => {
    operationRef.contents->Option.forEach(operation => {
      if removeOperation(runtime, id, operation, ~abort=true) {
        switch operation.kind {
        | RequestOperation(sessionToken) =>
          sendReply(runtime, sessionToken, id, ReplyError("Request timed out"))
        | CastOperation => ()
        }
      }
    })
  }, runtime.limits.requestTimeoutMs)
  let operation = {kind, phase, timeoutId}
  operationRef := Some(operation)
  runtime.operations->Map.set(id, operation)
  operation
}

let reserveDirectRequest = (runtime, sessionToken, id) => {
  if runtime.operations->Map.size >= runtime.limits.maxPendingRequests {
    markSettled(runtime, id)
    sendReply(runtime, sessionToken, id, ReplyError("Too many pending requests"))
    None
  } else {
    let controller = AbortController.make()
    let operation = startOperation(
      runtime,
      id,
      RequestOperation(sessionToken),
      Executing(controller),
    )
    Some((operation, controller))
  }
}

let runCastHandler = (runtime, message, sender) => {
  try {
    switch runtime.handler(message, sender, Cast) {
    | Response.RespondLater(promise) =>
      promise->Promise.thenResolve(_ => ())->Promise.catch(_ => Promise.resolve())->ignore
    | Response.RespondNow(_) | Response.NoResponse => ()
    }
  } catch {
  | _ => ()
  }
}

let sameOperationKind = (left, right) =>
  switch (left, right) {
  | (RequestOperation(_), RequestOperation(_)) | (CastOperation, CastOperation) => true
  | (RequestOperation(_), CastOperation) | (CastOperation, RequestOperation(_)) => false
  }

let sendOperationFailure = (runtime, id, kind, message) => {
  switch kind {
  | RequestOperation(sessionToken) => sendReply(runtime, sessionToken, id, ReplyError(message))
  | CastOperation => ()
  }
}

let failAssembly = (runtime, id, kind, message) => {
  let failed = switch runtime.operations->Map.get(id) {
  | Some(operation)
    if operation.kind->sameOperationKind(kind) &&
      switch operation.phase {
      | Assembling(_) => true
      | Executing(_) => false
      } =>
    removeOperation(runtime, id, operation, ~abort=false)
  | None => {
      markSettled(runtime, id)
      true
    }
  | Some(_) => false
  }
  if failed {
    sendOperationFailure(runtime, id, kind, message)
  }
}

let handleChunk = (runtime, id, index, total, body, sender, kind) => {
  let malformed = () => failAssembly(runtime, id, kind, "Malformed chunk sequence")
  if runtime.settled->Map.has(id) {
    ()
  } else if (
    index < 0 ||
    total <= 0 ||
    total > MessageChunker.maxChunksPerMessage ||
    index >= total ||
    body === ""
  ) {
    malformed()
  } else {
    let bodyBytes = body->MessageChunker.stringByteLength
    if bodyBytes > runtime.transport.maxChunkBytes {
      failAssembly(runtime, id, kind, "Chunk exceeds maxChunkBytes")
    } else {
      let operation = switch runtime.operations->Map.get(id) {
      | None if index !== 0 => {
          malformed()
          None
        }
      | None if runtime.operations->Map.size < runtime.limits.maxPendingRequests => {
          let assembly = {total, bytes: 0, body: []}
          Some(startOperation(runtime, id, kind, Assembling(assembly)))
        }
      | Some(operation) => Some(operation)
      | None => {
          markSettled(runtime, id)
          sendOperationFailure(runtime, id, kind, "Too many pending requests")
          None
        }
      }
      switch operation {
      | Some(operation) if !(operation.kind->sameOperationKind(kind)) => malformed()
      | Some({phase: Assembling(assembly), _})
        if assembly.total !== total ||
        assembly.body->Array.length !== index ||
        assembly.bytes + bodyBytes > runtime.limits.maxMessageBytes =>
        malformed()
      | Some({phase: Assembling(_), _})
        if runtime.assemblyBytes.contents + bodyBytes > runtime.limits.maxMessageBytes =>
        failAssembly(runtime, id, kind, "Chunk allocation exceeds maxMessageBytes")
      | Some({phase: Executing(_), _}) => ()
      | Some({phase: Assembling(assembly), _} as operation) => {
          assembly.body->Array.push(body)->ignore
          assembly.bytes = assembly.bytes + bodyBytes
          runtime.assemblyBytes := runtime.assemblyBytes.contents + bodyBytes
          if assembly.body->Array.length === total {
            try {
              let message = assembly.body->Array.join("")->JSON.parseOrThrow->Obj.magic
              switch kind {
              | RequestOperation(sessionToken) => {
                  runtime.assemblyBytes := runtime.assemblyBytes.contents - assembly.bytes
                  let controller = AbortController.make()
                  operation.phase = Executing(controller)
                  markSettled(runtime, id)
                  executeRequest(runtime, sessionToken, id, message, sender, operation, controller)
                }
              | CastOperation =>
                if removeOperation(runtime, id, operation, ~abort=false) {
                  runCastHandler(runtime, message, sender)
                }
              }
            } catch {
            | _ => malformed()
            }
          }
        }
      | None => ()
      }
    }
  }
}

let isValidId = id => {
  if Type.typeof(Obj.magic(id)) !== #string {
    false
  } else {
    let value = id->Id.toString
    value !== "" && value->String.length <= 64
  }
}

let hasValidId = (rawMessage, id) => hasOwn(rawMessage, "id") && isValidId(id)

let sessionIsOpen = (runtime, sessionToken) =>
  switch runtime.lifecycle.contents {
  | LifecycleOpen(current) => current === sessionToken
  | LifecycleConnecting(_) | LifecycleDisconnected(_) | LifecycleClosed(_) => false
  }

let operationIsActive = (runtime, id, expected) =>
  switch runtime.operations->Map.get(id) {
  | Some(operation) => operation === expected
  | None => false
  }

let handleDirectRequest = (runtime, sessionToken, id, message, sender) => {
  if !(runtime.operations->Map.has(id)) && !(runtime.settled->Map.has(id)) {
    switch reserveDirectRequest(runtime, sessionToken, id) {
    | Some((operation, controller)) =>
      switch normalizePayload(runtime, message) {
      | Ok(message)
        if operationIsActive(runtime, id, operation) && sessionIsOpen(runtime, sessionToken) =>
        executeRequest(runtime, sessionToken, id, message, sender, operation, controller)
      | Ok(_) => ()
      | Error(issue) =>
        if removeOperation(runtime, id, operation, ~abort=false) {
          let message = switch issue {
          | OversizedPayload => "Message exceeds maxMessageBytes"
          | InvalidPayload => "Invalid request payload"
          }
          sendReply(runtime, sessionToken, id, ReplyError(message))
        }
      }
    | None => ()
    }
  }
}

let handleDirectCast = (runtime, sessionToken, message, sender) => {
  switch normalizePayload(runtime, message) {
  | Ok(message) if sessionIsOpen(runtime, sessionToken) => runCastHandler(runtime, message, sender)
  | Ok(_) | Error(OversizedPayload | InvalidPayload) => ()
  }
}

let isValidChunkMessage = (rawMessage, id, index, total, body) =>
  hasValidId(rawMessage, id) &&
  hasOwn(rawMessage, "index") &&
  isSafeInteger(Obj.magic(index)) &&
  hasOwn(rawMessage, "total") &&
  isSafeInteger(Obj.magic(total)) &&
  hasOwn(rawMessage, "body") &&
  Type.typeof(Obj.magic(body)) === #string

let handleMessage = (runtime, sessionToken, rawMessage, sender) => {
  try {
    switch (Obj.magic(rawMessage): protocolMessage) {
    | Success({id, value}) if hasValidId(rawMessage, id) && hasOwn(rawMessage, "value") =>
      switch normalizePayload(runtime, value) {
      | Ok(value) =>
        switch takePending(runtime, id) {
        | Some(pending) => pending.resolve(value)
        | None => ()
        }
      | Error(OversizedPayload | InvalidPayload) =>
        rejectPending(runtime, id, "Invalid response payload")
      }
    | Success({id, _}) if hasValidId(rawMessage, id) =>
      rejectPending(runtime, id, "Invalid response payload")
    | Failure({id, message})
      if hasValidId(rawMessage, id) &&
      hasOwn(rawMessage, "message") &&
      Type.typeof(Obj.magic(message)) === #string &&
      message->MessageChunker.stringByteLength <= runtime.limits.maxMessageBytes =>
      rejectPending(runtime, id, message)
    | Failure({id, _}) if hasValidId(rawMessage, id) =>
      rejectPending(runtime, id, "Invalid response payload")
    | Request({id, message}) if hasValidId(rawMessage, id) && hasOwn(rawMessage, "message") =>
      handleDirectRequest(runtime, sessionToken, id, message, sender)
    | RequestChunk({id, index, total, body})
      if isValidChunkMessage(rawMessage, id, index, total, body) =>
      handleChunk(runtime, id, index, total, body, sender, RequestOperation(sessionToken))
    | RequestChunk({id, _}) if hasValidId(rawMessage, id) =>
      failAssembly(runtime, id, RequestOperation(sessionToken), "Malformed chunk sequence")
    | Cast(message) if hasOwn(rawMessage, "_0") =>
      handleDirectCast(runtime, sessionToken, message, sender)
    | CastChunk({id, index, total, body})
      if isValidChunkMessage(rawMessage, id, index, total, body) =>
      handleChunk(runtime, id, index, total, body, sender, CastOperation)
    | CastChunk({id, _}) if hasValidId(rawMessage, id) =>
      failAssembly(runtime, id, CastOperation, "Malformed chunk sequence")
    | Cancel(id) if hasOwn(rawMessage, "_0") && isValidId(id) =>
      switch runtime.operations->Map.get(id) {
      | Some(operation) => removeOperation(runtime, id, operation, ~abort=true)->ignore
      | None => ()
      }
    | Success(_)
    | Failure(_)
    | Request(_)
    | RequestChunk(_)
    | Cast(_)
    | CastChunk(_)
    | Cancel(_) => ()
    }
  } catch {
  | _ => ()
  }
}

let prepareRuntimeSession = (runtime): session<'sender> => {
  let sessionToken = ref()
  runtime.latestPreparedSessionToken := Some(sessionToken)
  let session = {
    connecting: () => {
      if runtime.latestPreparedSessionToken.contents === Some(sessionToken) {
        runtime.latestPreparedSessionToken := None
        let connect = replaced => {
          let connecting = LifecycleConnecting(Some(sessionToken))
          runtime.lifecycle := connecting
          if replaced {
            clearCurrentWork(runtime, "Connection replaced")
          }
          notifyStatus(runtime, connecting)
        }
        switch runtime.lifecycle.contents {
        | LifecycleClosed(_) => ()
        | LifecycleConnecting(Some(_)) | LifecycleOpen(_) => connect(true)
        | LifecycleConnecting(None) | LifecycleDisconnected(_) => connect(false)
        }
      }
    },
    opened: () => {
      switch runtime.lifecycle.contents {
      | LifecycleConnecting(Some(current)) if current === sessionToken => {
          let opened = LifecycleOpen(sessionToken)
          runtime.lifecycle := opened
          notifyStatus(runtime, opened)
        }
      | LifecycleConnecting(_)
      | LifecycleOpen(_)
      | LifecycleDisconnected(_)
      | LifecycleClosed(_) => ()
      }
    },
    message: (payload, sender) => {
      switch runtime.lifecycle.contents {
      | LifecycleOpen(current) if current === sessionToken =>
        handleMessage(runtime, sessionToken, payload, sender)
      | LifecycleConnecting(_)
      | LifecycleOpen(_)
      | LifecycleDisconnected(_)
      | LifecycleClosed(_) => ()
      }
    },
    disconnected: reason => {
      switch runtime.lifecycle.contents {
      | LifecycleConnecting(Some(current)) | LifecycleOpen(current) if current === sessionToken => {
          let disconnected = LifecycleDisconnected(reason)
          runtime.lifecycle := disconnected
          clearCurrentWork(runtime, reason)
          notifyStatus(runtime, disconnected)
        }
      | LifecycleConnecting(_)
      | LifecycleOpen(_)
      | LifecycleDisconnected(_)
      | LifecycleClosed(_) => ()
      }
    },
  }
  session
}

let make:
  type sender response. (
    transport<sender>,
    ~limits: limits,
    ~handler: (Types.message<response>, sender, context) => Response.t<response>,
  ) => t<sender> =
  (transport, ~limits, ~handler) => {
    if transport.consumed.contents {
      JsError.throwWithMessage("Transport has already been consumed")
    }
    if (
      !isSafeInteger(Obj.magic(limits.requestTimeoutMs)) ||
      !isSafeInteger(Obj.magic(limits.maxMessageBytes)) ||
      !isSafeInteger(Obj.magic(limits.maxPendingRequests)) ||
      limits.requestTimeoutMs <= 0 ||
      limits.maxMessageBytes < 64 ||
      limits.maxMessageBytes > 1_000_000_000 ||
      limits.maxPendingRequests <= 0 ||
      limits.maxPendingRequests > 1_000_000
    ) {
      JsError.throwWithMessage("Runtime limits are invalid")
    }
    transport.consumed := true
    let runtime = {
      transport,
      limits,
      handler: Obj.magic(handler),
      pending: Map.make(),
      operations: Map.make(),
      settled: Map.make(),
      statusListeners: ref([]),
      latestPreparedSessionToken: ref(None),
      lifecycle: ref(LifecycleConnecting(None)),
      assemblyBytes: ref(0),
    }
    try {
      transport.start(~prepareSession=() => prepareRuntimeSession(runtime))
    } catch {
    | error => {
        try {
          transport.close()
        } catch {
        | _ => ()
        }
        JsError.throw(Obj.magic(error))
      }
    }
    runtime
  }

let sendPreparedRequest = (
  runtime,
  sessionToken,
  prepared: MessageChunker.preparedJson,
  ~signal=?,
) => {
  switch runtime.lifecycle.contents {
  | LifecycleOpen(current)
    if current === sessionToken && runtime.pending->Map.size >= runtime.limits.maxPendingRequests =>
    rejectedPromise("Too many pending requests")
  | LifecycleOpen(current) if current === sessionToken => {
      let id = Id.make()
      Promise.make((resolve, reject) => {
        if signal->Option.mapOr(false, AbortSignal.aborted) {
          reject(JsError.make("Request aborted"))
        } else {
          let abortHandler = () =>
            rejectPending(runtime, id, "Request aborted", ~cancelSession=sessionToken)
          let removeAbortListener = switch signal {
          | Some(signal) => AbortSignal.onAbort(signal, abortHandler)
          | None => () => ()
          }
          let timeoutId = setTimeout(
            () => rejectPending(runtime, id, "Request timed out", ~cancelSession=sessionToken),
            runtime.limits.requestTimeoutMs,
          )
          runtime.pending->Map.set(
            id,
            {
              resolve: value => resolve(Obj.magic(value)),
              reject,
              timeoutId,
              removeAbortListener,
            },
          )
          try {
            switch prepared->MessageChunker.chunkPrepared(~size=runtime.transport.maxChunkBytes) {
            | Some(chunks) => sendChunks(runtime, sessionToken, id, chunks, RequestChunks)
            | None =>
              sendProtocol(
                runtime,
                sessionToken,
                (Request({id, message: prepared.value}): protocolMessage),
              )
            }
          } catch {
          | error =>
            if runtime.pending->Map.has(id) {
              rejectPending(runtime, id, exceptionMessage(error))
            }
          }
        }
      })
    }
  | LifecycleConnecting(_) | LifecycleOpen(_) | LifecycleDisconnected(_) | LifecycleClosed(_) =>
    rejectedPromise("Runtime is not connected")
  }
}

let sendMessage:
  type sender response. (
    t<sender>,
    Types.message<response>,
    ~signal: AbortSignal.t=?,
  ) => Promise.t<response> =
  (runtime, message, ~signal=?) => {
    switch runtime.lifecycle.contents {
    | LifecycleOpen(sessionToken) =>
      try {
        switch message->MessageChunker.prepareJsonWithin(~maxBytes=runtime.limits.maxMessageBytes) {
        | Some(prepared) =>
          sendPreparedRequest(runtime, sessionToken, prepared, ~signal?)->Obj.magic
        | None => rejectedPromise("Message exceeds maxMessageBytes")
        }
      } catch {
      | error => Promise.reject(error)
      }
    | LifecycleConnecting(_) | LifecycleDisconnected(_) | LifecycleClosed(_) =>
      rejectedPromise("Runtime is not connected")
    }
  }

let cast:
  type sender. (t<sender>, Types.message<unit>) => unit =
  (runtime, message) => {
    let sessionToken = switch runtime.lifecycle.contents {
    | LifecycleOpen(sessionToken) => sessionToken
    | LifecycleClosed(_) => JsError.throwWithMessage("Runtime is closed")
    | LifecycleConnecting(_) | LifecycleDisconnected(_) =>
      JsError.throwWithMessage("Runtime is not connected")
    }
    let prepared = switch message->MessageChunker.prepareJsonWithin(
      ~maxBytes=runtime.limits.maxMessageBytes,
    ) {
    | Some(prepared) => prepared
    | None => JsError.throwWithMessage("Message exceeds maxMessageBytes")
    }
    switch prepared->MessageChunker.chunkPrepared(~size=runtime.transport.maxChunkBytes) {
    | Some(chunks) =>
      let id = Id.make()
      try {
        sendChunks(runtime, sessionToken, id, chunks, CastChunks)
      } catch {
      | error => JsError.throwWithMessage(exceptionMessage(error))
      }
    | None => sendProtocol(runtime, sessionToken, (Cast(prepared.value): protocolMessage))
    }
  }

let close = runtime => {
  switch runtime.lifecycle.contents {
  | LifecycleClosed(_) => ()
  | LifecycleConnecting(_) | LifecycleOpen(_) | LifecycleDisconnected(_) => {
      let reason = "Runtime closed"
      let closed = LifecycleClosed(reason)
      runtime.lifecycle := closed
      runtime.latestPreparedSessionToken := None
      clearCurrentWork(runtime, reason)
      try {
        runtime.transport.close()
      } catch {
      | error => Console.error2("Transport teardown failed:", error)
      }
      notifyStatus(runtime, closed)
      runtime.statusListeners := []
    }
  }
}
