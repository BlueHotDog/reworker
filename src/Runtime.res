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
type sessionToken = ref<bool>

type protocolMessage =
  | Request({id: Id.t, message: Obj.t})
  | RequestChunk({id: Id.t, index: int, total: int, body: string})
  | Cast(Obj.t)
  | CastChunk({id: Id.t, index: int, total: int, body: string})
  | Cancel(Id.t)
  | Success({id: Id.t, value: Obj.t})
  | Failure({id: Id.t, message: string})

type pendingRequest = {
  resolve: Obj.t => unit,
  reject: JsError.t => unit,
  timeoutId: timeoutId,
  removeAbortListener: unit => unit,
}

type assemblyKind = RequestAssembly | CastAssembly
type assembly = {
  kind: assemblyKind,
  total: int,
  nextIndex: ref<int>,
  bytes: ref<int>,
  body: array<string>,
  deadlineMs: float,
  timeoutId: timeoutId,
}
type execution = {
  controller: AbortController.t,
  timeoutId: timeoutId,
}
type operation = Assembling(assembly) | Executing(execution)

type registeredHandler<'sender> = (Obj.t, 'sender, context) => Response.t<Obj.t>

type t<'sender> = {
  transport: transport<'sender>,
  limits: limits,
  handler: registeredHandler<'sender>,
  pending: Map.t<Id.t, pendingRequest>,
  operations: Map.t<Id.t, operation>,
  settled: Set.t<Id.t>,
  settledOrder: ref<array<Id.t>>,
  settledIndex: ref<int>,
  statusListeners: ref<array<status => unit>>,
  latestPreparedSessionToken: ref<option<sessionToken>>,
  currentSessionToken: ref<option<sessionToken>>,
  currentStatus: ref<status>,
  assemblyBytes: ref<int>,
  teardown: ref<unit => unit>,
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

let removeFirst = (listeners, listener) => {
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

let notifyStatus = (runtime, committedStatus) => {
  runtime.statusListeners.contents->Array.forEach(listener => {
    if runtime.currentStatus.contents === committedStatus {
      try {
        listener(committedStatus)
      } catch {
      | error => Console.error2("Status listener failed:", error)
      }
    }
  })
}

let setStatus = (runtime, nextStatus) => {
  runtime.currentStatus := nextStatus
  notifyStatus(runtime, nextStatus)
}

let status = runtime => runtime.currentStatus.contents

let onStatus = (runtime, listener) => {
  switch runtime.currentStatus.contents {
  | Closed(_) => () => ()
  | Connecting | Open | Disconnected(_) => {
      runtime.statusListeners := runtime.statusListeners.contents->Array.concat([listener])
      let subscribed = ref(true)
      () => {
        if subscribed.contents {
          subscribed := false
          removeFirst(runtime.statusListeners, listener)
        }
      }
    }
  }
}

let markSettled = (runtime, id) => {
  if !(runtime.settled->Set.has(id)) {
    let capacity = runtime.limits.maxPendingRequests + 1
    if runtime.settledOrder.contents->Array.length < capacity {
      runtime.settledOrder.contents->Array.push(id)->ignore
    } else {
      runtime.settledOrder.contents
      ->Array.get(runtime.settledIndex.contents)
      ->Option.forEach(oldest => runtime.settled->Set.delete(oldest)->ignore)
      runtime.settledOrder.contents[runtime.settledIndex.contents] = id
      runtime.settledIndex := (runtime.settledIndex.contents + 1) % capacity
    }
    runtime.settled->Set.add(id)
  }
}

let sendProtocol = (runtime, message) => {
  switch runtime.currentStatus.contents {
  | Closed(_) => JsError.throwWithMessage("Runtime is closed")
  | Connecting | Disconnected(_) => JsError.throwWithMessage("Runtime is not connected")
  | Open =>
    switch runtime.transport.postMessage(Obj.magic(message)) {
    | Ok() => ()
    | Error(message) => JsError.throwWithMessage(message)
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

let rejectPending = (runtime, id, message, ~cancelRemote=false) => {
  switch takePending(runtime, id) {
  | Some(pending) => {
      pending.reject(JsError.make(message))
      if cancelRemote {
        try {
          sendProtocol(runtime, Cancel(id))
        } catch {
        | _ => ()
        }
      }
    }
  | None => ()
  }
}

let removeAssembly = (runtime, id, expected) => {
  switch runtime.operations->Map.get(id) {
  | Some(Assembling(assembly)) if assembly === expected => {
      clearTimeout(assembly.timeoutId)
      runtime.operations->Map.delete(id)->ignore
      runtime.assemblyBytes := runtime.assemblyBytes.contents - assembly.bytes.contents
      markSettled(runtime, id)
      true
    }
  | Some(Assembling(_)) | Some(Executing(_)) | None => false
  }
}

let removeExecution = (runtime, id, expected, ~abort) => {
  switch runtime.operations->Map.get(id) {
  | Some(Executing(execution)) if execution === expected => {
      clearTimeout(execution.timeoutId)
      runtime.operations->Map.delete(id)->ignore
      markSettled(runtime, id)
      if abort {
        execution.controller->AbortController.abort
      }
      true
    }
  | Some(Assembling(_)) | Some(Executing(_)) | None => false
  }
}

let whenOpen = runtime =>
  switch runtime.currentStatus.contents {
  | Open => Promise.resolve()
  | Closed(reason) => rejectedPromise(reason)
  | Connecting | Disconnected(_) =>
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
  runtime.pending->Map.clear
  pendingRequests->Array.forEach(pending => {
    clearTimeout(pending.timeoutId)
    pending.removeAbortListener()
    pending.reject(JsError.make(reason))
  })

  let operations = []
  runtime.operations->Map.forEachWithKey((operation, id) => {
    operations->Array.push((id, operation))->ignore
  })
  operations->Array.forEach(((id, operation)) => {
    switch operation {
    | Assembling(assembly) => removeAssembly(runtime, id, assembly)->ignore
    | Executing(execution) => removeExecution(runtime, id, execution, ~abort=true)->ignore
    }
  })
  runtime.assemblyBytes := 0
  runtime.settled->Set.clear
  runtime.settledOrder := []
  runtime.settledIndex := 0
}

let sendResponse = (runtime, sessionToken, response) => {
  if runtime.currentSessionToken.contents === Some(sessionToken) {
    let bounded: protocolMessage = switch response {
    | Success({id, value}) =>
      try {
        switch value->MessageChunker.prepareJsonWithin(~maxBytes=runtime.limits.maxMessageBytes) {
        | Some(prepared) => Success({id, value: prepared.value})
        | None => Failure({id, message: "Response exceeds maxMessageBytes"})
        }
      } catch {
      | _ => Failure({id, message: "Response could not be serialized"})
      }
    | Failure({id, message})
      if message->MessageChunker.stringByteLength > runtime.limits.maxMessageBytes =>
      Failure({id, message: "Remote error exceeds maxMessageBytes"})
    | Failure(_) | Request(_) | RequestChunk(_) | Cast(_) | CastChunk(_) | Cancel(_) => response
    }
    try {
      sendProtocol(runtime, bounded)
    } catch {
    | _ =>
      switch bounded {
      | Success({id, value: _}) =>
        try {
          sendProtocol(
            runtime,
            (Failure({id, message: "Response could not be cloned"}): protocolMessage),
          )
        } catch {
        | _ => ()
        }
      | Failure(_) | Request(_) | RequestChunk(_) | Cast(_) | CastChunk(_) | Cancel(_) => ()
      }
    }
  }
}

let finishExecution = (runtime, id, execution: execution) =>
  removeExecution(runtime, id, execution, ~abort=false)

let runRequestHandler = (runtime, sessionToken, id, message, sender, ~deadlineMs=?) => {
  if runtime.operations->Map.size >= runtime.limits.maxPendingRequests {
    markSettled(runtime, id)
    sendResponse(runtime, sessionToken, Failure({id, message: "Too many pending requests"}))
  } else {
    let controller = AbortController.make()
    let executionRef: ref<option<execution>> = ref(None)
    let onTimeout = () => {
      executionRef.contents->Option.forEach(execution => {
        if removeExecution(runtime, id, execution, ~abort=true) {
          sendResponse(runtime, sessionToken, Failure({id, message: "Request timed out"}))
        }
      })
    }
    let timeoutId = switch deadlineMs {
    | Some(deadlineMs) => {
        let remainingMs = deadlineMs - Date.now()
        setTimeoutFloat(onTimeout, remainingMs > 0.0 ? remainingMs : 0.0)
      }
    | None => setTimeout(onTimeout, runtime.limits.requestTimeoutMs)
    }
    let execution = {controller, timeoutId}
    executionRef := Some(execution)
    runtime.operations->Map.set(id, Executing(execution))
    try {
      switch runtime.handler(
        message,
        sender,
        Request(execution.controller->AbortController.signal),
      ) {
      | Response.RespondNow(value) =>
        if finishExecution(runtime, id, execution) {
          sendResponse(runtime, sessionToken, Success({id, value}))
        }
      | Response.RespondLater(promise) =>
        promise
        ->Promise.thenResolve(value => {
          if finishExecution(runtime, id, execution) {
            sendResponse(runtime, sessionToken, Success({id, value}))
          }
        })
        ->Promise.catch(error => {
          if finishExecution(runtime, id, execution) {
            sendResponse(runtime, sessionToken, Failure({id, message: exceptionMessage(error)}))
          }
          Promise.resolve()
        })
        ->ignore
      | Response.NoResponse =>
        if finishExecution(runtime, id, execution) {
          sendResponse(runtime, sessionToken, Failure({id, message: "Handler did not respond"}))
        }
      }
    } catch {
    | error =>
      if finishExecution(runtime, id, execution) {
        sendResponse(runtime, sessionToken, Failure({id, message: exceptionMessage(error)}))
      }
    }
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

let failAssembly = (runtime, sessionToken, id, kind, message, ~respond) => {
  switch runtime.operations->Map.get(id) {
  | Some(Assembling(assembly)) if assembly.kind === kind =>
    removeAssembly(runtime, id, assembly)->ignore
  | None => markSettled(runtime, id)
  | Some(Assembling(_)) | Some(Executing(_)) => ()
  }
  if respond {
    sendResponse(runtime, sessionToken, Failure({id, message}))
  }
}

let handleChunk = (runtime, sessionToken, id, index, total, body, sender, kind) => {
  let respond = kind === RequestAssembly
  let malformed = () =>
    failAssembly(runtime, sessionToken, id, kind, "Malformed chunk sequence", ~respond)
  if runtime.settled->Set.has(id) {
    ()
  } else if (
    !isSafeInteger(Obj.magic(index)) ||
    !isSafeInteger(Obj.magic(total)) ||
    index < 0 ||
    total <= 0 ||
    total > MessageChunker.maxChunksPerMessage ||
    index >= total ||
    Type.typeof(Obj.magic(body)) !== #string ||
    body === ""
  ) {
    malformed()
  } else {
    let bodyBytes = body->MessageChunker.stringByteLength
    if bodyBytes > runtime.transport.maxChunkBytes {
      failAssembly(runtime, sessionToken, id, kind, "Chunk exceeds maxChunkBytes", ~respond)
    } else {
      let assembly = switch runtime.operations->Map.get(id) {
      | None if index !== 0 => {
          malformed()
          None
        }
      | None if runtime.operations->Map.size < runtime.limits.maxPendingRequests => {
          let assemblyRef: ref<option<assembly>> = ref(None)
          let deadlineMs = Date.now() + runtime.limits.requestTimeoutMs->Int.toFloat
          let timeoutId = setTimeoutFloat(() => {
            assemblyRef.contents->Option.forEach(assembly => {
              if removeAssembly(runtime, id, assembly) && kind === RequestAssembly {
                sendResponse(runtime, sessionToken, Failure({id, message: "Request timed out"}))
              }
            })
          }, deadlineMs - Date.now())
          let assembly = {
            kind,
            total,
            nextIndex: ref(0),
            bytes: ref(0),
            body: [],
            deadlineMs,
            timeoutId,
          }
          assemblyRef := Some(assembly)
          runtime.operations->Map.set(id, Assembling(assembly))
          Some(assembly)
        }
      | Some(Assembling(assembly)) => Some(assembly)
      | None => {
          markSettled(runtime, id)
          if respond {
            sendResponse(runtime, sessionToken, Failure({id, message: "Too many pending requests"}))
          }
          None
        }
      | Some(Executing(_)) => {
          if respond {
            sendResponse(runtime, sessionToken, Failure({id, message: "Duplicate request"}))
          }
          None
        }
      }
      switch assembly {
      | Some(assembly)
        if assembly.kind !== kind ||
        assembly.total !== total ||
        assembly.nextIndex.contents !== index ||
        assembly.bytes.contents + bodyBytes > runtime.limits.maxMessageBytes =>
        malformed()
      | Some(_) if runtime.assemblyBytes.contents + bodyBytes > runtime.limits.maxMessageBytes =>
        failAssembly(
          runtime,
          sessionToken,
          id,
          kind,
          "Chunk allocation exceeds maxMessageBytes",
          ~respond,
        )
      | Some(assembly) => {
          assembly.body->Array.push(body)->ignore
          assembly.bytes := assembly.bytes.contents + bodyBytes
          runtime.assemblyBytes := runtime.assemblyBytes.contents + bodyBytes
          assembly.nextIndex := assembly.nextIndex.contents + 1
          if assembly.nextIndex.contents === total {
            removeAssembly(runtime, id, assembly)->ignore
            try {
              let message = assembly.body->Array.join("")->JSON.parseOrThrow->Obj.magic
              switch kind {
              | RequestAssembly =>
                runRequestHandler(
                  runtime,
                  sessionToken,
                  id,
                  message,
                  sender,
                  ~deadlineMs=assembly.deadlineMs,
                )
              | CastAssembly => runCastHandler(runtime, message, sender)
              }
            } catch {
            | _ =>
              if respond {
                sendResponse(
                  runtime,
                  sessionToken,
                  Failure({id, message: "Malformed chunk sequence"}),
                )
              }
            }
          }
        }
      | None => ()
      }
    }
  }
}

let isValidId = id =>
  Type.typeof(Obj.magic(id)) === #string &&
  id->Id.toString !== "" &&
  id->Id.toString->String.length <= 64
let handleMessage = (runtime, sessionToken, rawMessage, sender) => {
  try {
    switch (Obj.magic(rawMessage): protocolMessage) {
    | Success({id, value}) =>
      if hasOwn(rawMessage, "id") && isValidId(id) {
        if !hasOwn(rawMessage, "value") {
          rejectPending(runtime, id, "Invalid response payload")
        } else {
          try {
            switch value->MessageChunker.prepareJsonWithin(
              ~maxBytes=runtime.limits.maxMessageBytes,
            ) {
            | Some(prepared) =>
              switch takePending(runtime, id) {
              | Some(pending) => pending.resolve(prepared.value)
              | None => ()
              }
            | None => rejectPending(runtime, id, "Invalid response payload")
            }
          } catch {
          | _ => rejectPending(runtime, id, "Invalid response payload")
          }
        }
      }
    | Failure({id, message}) =>
      if hasOwn(rawMessage, "id") && isValidId(id) {
        if (
          !hasOwn(rawMessage, "message") ||
          Type.typeof(Obj.magic(message)) !== #string ||
          message->MessageChunker.stringByteLength > runtime.limits.maxMessageBytes
        ) {
          rejectPending(runtime, id, "Invalid response payload")
        } else {
          rejectPending(runtime, id, message)
        }
      }
    | Request({id, message}) =>
      if hasOwn(rawMessage, "id") && isValidId(id) && hasOwn(rawMessage, "message") {
        switch (runtime.operations->Map.get(id), runtime.settled->Set.has(id)) {
        | (Some(_), _) => ()
        | (None, true) => ()
        | (None, false) =>
          try {
            switch message->MessageChunker.prepareJsonWithin(
              ~maxBytes=runtime.limits.maxMessageBytes,
            ) {
            | None =>
              sendResponse(
                runtime,
                sessionToken,
                Failure({id, message: "Message exceeds maxMessageBytes"}),
              )
            | Some(prepared) => runRequestHandler(runtime, sessionToken, id, prepared.value, sender)
            }
          } catch {
          | _ =>
            sendResponse(runtime, sessionToken, Failure({id, message: "Invalid request payload"}))
          }
        }
      }
    | RequestChunk({id, index, total, body}) =>
      if (
        hasOwn(rawMessage, "id") &&
        isValidId(id) &&
        hasOwn(rawMessage, "index") &&
        isSafeInteger(Obj.magic(index)) &&
        hasOwn(rawMessage, "total") &&
        isSafeInteger(Obj.magic(total)) &&
        hasOwn(rawMessage, "body") &&
        Type.typeof(Obj.magic(body)) === #string
      ) {
        handleChunk(runtime, sessionToken, id, index, total, body, sender, RequestAssembly)
      }
    | Cast(message) =>
      if hasOwn(rawMessage, "_0") {
        try {
          switch message->MessageChunker.prepareJsonWithin(
            ~maxBytes=runtime.limits.maxMessageBytes,
          ) {
          | Some(prepared) => runCastHandler(runtime, prepared.value, sender)
          | None => ()
          }
        } catch {
        | _ => ()
        }
      }
    | CastChunk({id, index, total, body}) =>
      if (
        hasOwn(rawMessage, "id") &&
        isValidId(id) &&
        hasOwn(rawMessage, "index") &&
        isSafeInteger(Obj.magic(index)) &&
        hasOwn(rawMessage, "total") &&
        isSafeInteger(Obj.magic(total)) &&
        hasOwn(rawMessage, "body") &&
        Type.typeof(Obj.magic(body)) === #string
      ) {
        handleChunk(runtime, sessionToken, id, index, total, body, sender, CastAssembly)
      }
    | Cancel(id) =>
      if hasOwn(rawMessage, "_0") && isValidId(id) {
        switch runtime.operations->Map.get(id) {
        | Some(Executing(execution)) => removeExecution(runtime, id, execution, ~abort=true)->ignore
        | Some(Assembling(assembly)) => removeAssembly(runtime, id, assembly)->ignore
        | None => ()
        }
      }
    }
  } catch {
  | _ => ()
  }
}

let prepareRuntimeSession = (runtime): session<'sender> => {
  let sessionToken = ref(false)
  runtime.latestPreparedSessionToken := Some(sessionToken)
  let session = {
    connecting: () => {
      if (
        !sessionToken.contents && runtime.latestPreparedSessionToken.contents === Some(sessionToken)
      ) {
        sessionToken := true
        switch runtime.currentStatus.contents {
        | Closed(_) => ()
        | Connecting | Open | Disconnected(_) => {
            let previous = runtime.currentSessionToken.contents
            runtime.currentSessionToken := Some(sessionToken)
            runtime.currentStatus := Connecting
            previous->Option.forEach(_ => clearCurrentWork(runtime, "Connection replaced"))
            notifyStatus(runtime, Connecting)
          }
        }
      }
    },
    opened: () => {
      if (
        runtime.currentSessionToken.contents === Some(sessionToken) &&
          runtime.currentStatus.contents !== Open
      ) {
        runtime.currentStatus := Open
        notifyStatus(runtime, Open)
      }
    },
    message: (payload, sender) => {
      if (
        runtime.currentStatus.contents === Open &&
          runtime.currentSessionToken.contents === Some(sessionToken)
      ) {
        handleMessage(runtime, sessionToken, payload, sender)
      }
    },
    disconnected: reason => {
      if runtime.currentSessionToken.contents === Some(sessionToken) {
        runtime.currentSessionToken := None
        let disconnected: status = Disconnected(reason)
        runtime.currentStatus := disconnected
        clearCurrentWork(runtime, reason)
        notifyStatus(runtime, disconnected)
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
      settled: Set.make(),
      settledOrder: ref([]),
      settledIndex: ref(0),
      statusListeners: ref([]),
      latestPreparedSessionToken: ref(None),
      currentSessionToken: ref(None),
      currentStatus: ref(Connecting),
      assemblyBytes: ref(0),
      teardown: ref(() => ()),
    }
    runtime.teardown := transport.close
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

let sendPreparedRequest = (runtime, prepared: MessageChunker.preparedJson, ~signal=?) => {
  switch runtime.currentSessionToken.contents {
  | None => rejectedPromise("Runtime is not connected")
  | Some(_) if runtime.pending->Map.size >= runtime.limits.maxPendingRequests =>
    rejectedPromise("Too many pending requests")
  | Some(_) => {
      let id = Id.make()
      Promise.make((resolve, reject) => {
        if signal->Option.mapOr(false, AbortSignal.aborted) {
          reject(JsError.make("Request aborted"))
        } else {
          let abortHandler = () => rejectPending(runtime, id, "Request aborted", ~cancelRemote=true)
          let removeAbortListener = switch signal {
          | Some(signal) => AbortSignal.onAbort(signal, abortHandler)
          | None => () => ()
          }
          let timeoutId = setTimeout(
            () => rejectPending(runtime, id, "Request timed out", ~cancelRemote=true),
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
          let sentChunks = ref(0)
          try {
            switch prepared->MessageChunker.chunkPrepared(~size=runtime.transport.maxChunkBytes) {
            | Some(chunks) =>
              let index = ref(0)
              while index.contents < chunks->Array.length && runtime.pending->Map.has(id) {
                sendProtocol(
                  runtime,
                  RequestChunk({
                    id,
                    index: index.contents,
                    total: chunks->Array.length,
                    body: chunks[index.contents]->Option.getOrThrow,
                  }),
                )
                sentChunks := sentChunks.contents + 1
                index := index.contents + 1
              }
            | None =>
              sendProtocol(runtime, (Request({id, message: prepared.value}): protocolMessage))
            }
          } catch {
          | error =>
            if runtime.pending->Map.has(id) {
              if sentChunks.contents > 0 {
                try {
                  sendProtocol(runtime, Cancel(id))
                } catch {
                | _ => ()
                }
              }
              rejectPending(runtime, id, exceptionMessage(error))
            }
          }
        }
      })
    }
  }
}

let sendMessage:
  type sender response. (
    t<sender>,
    Types.message<response>,
    ~signal: AbortSignal.t=?,
  ) => Promise.t<response> =
  (runtime, message, ~signal=?) => {
    try {
      switch message->MessageChunker.prepareJsonWithin(~maxBytes=runtime.limits.maxMessageBytes) {
      | Some(prepared) => sendPreparedRequest(runtime, prepared, ~signal?)->Obj.magic
      | None => rejectedPromise("Message exceeds maxMessageBytes")
      }
    } catch {
    | error => Promise.reject(error)
    }
  }

let cast:
  type sender. (t<sender>, Types.message<unit>) => unit =
  (runtime, message) => {
    let prepared = switch message->MessageChunker.prepareJsonWithin(
      ~maxBytes=runtime.limits.maxMessageBytes,
    ) {
    | Some(prepared) => prepared
    | None => JsError.throwWithMessage("Message exceeds maxMessageBytes")
    }
    switch prepared->MessageChunker.chunkPrepared(~size=runtime.transport.maxChunkBytes) {
    | Some(chunks) =>
      let id = Id.make()
      let sent = ref(0)
      try {
        chunks->Array.forEachWithIndex((body, index) => {
          sendProtocol(
            runtime,
            CastChunk({
              id,
              index,
              total: chunks->Array.length,
              body,
            }),
          )
          sent := sent.contents + 1
        })
      } catch {
      | error => {
          if sent.contents > 0 {
            try {
              sendProtocol(runtime, Cancel(id))
            } catch {
            | _ => ()
            }
          }
          JsError.throwWithMessage(exceptionMessage(error))
        }
      }
    | None => sendProtocol(runtime, (Cast(prepared.value): protocolMessage))
    }
  }

let close = runtime => {
  switch runtime.currentStatus.contents {
  | Closed(_) => ()
  | Connecting | Open | Disconnected(_) => {
      let reason = "Runtime closed"
      runtime.currentStatus := Closed(reason)
      runtime.latestPreparedSessionToken := None
      runtime.currentSessionToken := None
      clearCurrentWork(runtime, reason)
      try {
        runtime.teardown.contents()
      } catch {
      | error => Console.error2("Transport teardown failed:", error)
      }
      setStatus(runtime, Closed(reason))
      runtime.statusListeners := []
    }
  }
}
