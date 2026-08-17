/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type messageListener<'sender> = (Obj.t, 'sender) => unit

type transport<'sender, 'extension> = {
  requestTimeoutMs: int,
  maxMessageBytes: int,
  maxPendingRequests: int,
  maxChunkBytes: int,
  postMessage: Obj.t => result<unit, string>,
  addMessageListener: messageListener<'sender> => unit,
  removeMessageListener: messageListener<'sender> => unit,
  addOpenListener: (unit => unit) => unit,
  removeOpenListener: (unit => unit) => unit,
  addCloseListener: (string => unit) => unit,
  removeCloseListener: (string => unit) => unit,
  isOpen: unit => bool,
  isCurrentSender: 'sender => bool,
  senderKey: 'sender => string,
  close: unit => unit,
  extension: 'extension,
}

type transportCore<'sender> = {
  requestTimeoutMs: int,
  maxMessageBytes: int,
  maxPendingRequests: int,
  maxChunkBytes: int,
  postMessage: Obj.t => result<unit, string>,
  addMessageListener: messageListener<'sender> => unit,
  removeMessageListener: messageListener<'sender> => unit,
  addOpenListener: (unit => unit) => unit,
  removeOpenListener: (unit => unit) => unit,
  addCloseListener: (string => unit) => unit,
  removeCloseListener: (string => unit) => unit,
  isOpen: unit => bool,
  isCurrentSender: 'sender => bool,
  senderKey: 'sender => string,
  close: unit => unit,
}

type cancellation = {
  requestId: option<Id.t>,
  assemblyId: option<Id.t>,
}

type castMessage = {
  id: Id.t,
  message: Obj.t,
}

type responseChunk = {
  id: Id.t,
  chunk: TransportMessage.chunk,
}

type protocolMessage =
  | Request({id: Id.t, message: Obj.t})
  | Cancel(cancellation)
  | Cast(castMessage)
  | Success({id: Id.t, value: Obj.t})
  | SuccessChunk(responseChunk)
  | Failure({id: Id.t, message: string})

@scope("Object") @val external hasOwn: (Obj.t, string) => bool = "hasOwn"

type responseAssembly = {
  messageId: Id.t,
  total: int,
  mutable bytes: int,
  chunks: Map.t<int, TransportMessage.chunk>,
}

type pendingRequest = {
  resolve: Obj.t => unit,
  reject: JsError.t => unit,
  timeoutId: timeoutId,
  removeAbortListener: unit => unit,
  mutable responseAssembly: option<responseAssembly>,
}

type registeredMessageHandler<'sender> = (
  Obj.t,
  'sender,
  option<AbortSignal.t>,
) => Response.t<Obj.t>

type activeRequest = {
  controller: AbortController.t,
  senderKey: string,
}

type t<'sender> = {
  transport: transportCore<'sender>,
  pendingRequests: Map.t<Id.t, pendingRequest>,
  mutable responseStoredBytes: int,
  mutable responseAssemblyCount: int,
  activeRequests: Map.t<Id.t, array<activeRequest>>,
  settledRequests: Map.t<string, Set.t<Id.t>>,
  requestHandler: RequestHandler.t,
  messageHandlers: ref<array<registeredMessageHandler<'sender>>>,
  inboundHandler: ref<messageListener<'sender>>,
  openListeners: ref<array<unit => unit>>,
  lifecycleCloseListeners: ref<array<string => unit>>,
  reconnectListeners: ref<array<unit => unit>>,
  mutable responseHandler: option<messageListener<'sender>>,
  mutable openHandler: option<unit => unit>,
  mutable closeHandler: option<string => unit>,
  mutable hasOpened: bool,
  mutable connectionOpen: bool,
  mutable closed: bool,
}

@val external errorToString: 'a => string = "String"
@scope("Number") @val external isSafeInteger: Obj.t => bool = "isSafeInteger"

let exceptionMessage = error => {
  error->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(errorToString(error))
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

let notifyListeners = listeners => {
  listeners->Array.forEach(listener => {
    try {
      listener()
    } catch {
    | error => Console.error2("Lifecycle listener failed:", error)
    }
  })
}

let notifyCloseListeners = (listeners, reason) => {
  listeners->Array.forEach(listener => {
    try {
      listener(reason)
    } catch {
    | error => Console.error2("Lifecycle listener failed:", error)
    }
  })
}

let sendProtocolMessage = (runtime, message) => {
  if runtime.closed {
    JsError.throwWithMessage("Runtime is closed")
  }
  switch runtime.transport.postMessage(Obj.magic(message)) {
  | Ok() => ()
  | Error(message) => JsError.throwWithMessage(message)
  }
}

let takePendingRequest = (runtime, id) => {
  switch runtime.pendingRequests->Map.get(id) {
  | Some(pending) => {
      clearTimeout(pending.timeoutId)
      pending.removeAbortListener()
      switch pending.responseAssembly {
      | Some(assembly) => {
          runtime.responseStoredBytes = runtime.responseStoredBytes - assembly.bytes
          runtime.responseAssemblyCount = runtime.responseAssemblyCount - 1
        }
      | None => ()
      }
      runtime.pendingRequests->Map.delete(id)->ignore
      Some(pending)
    }
  | None => None
  }
}

let sendCancellation = (runtime, requestId, assemblyId) => {
  if !runtime.closed {
    try {
      sendProtocolMessage(runtime, (Cancel({requestId, assemblyId}): protocolMessage))
    } catch {
    | _ => ()
    }
  }
}

let rejectPendingRequest = (runtime, id, message, ~notifyRemote=false, ~assemblyId=None) => {
  switch takePendingRequest(runtime, id) {
  | Some(pending) => {
      pending.reject(JsError.make(message))
      if notifyRemote {
        sendCancellation(runtime, Some(id), assemblyId)
      }
    }
  | None => ()
  }
}

let clearPendingRequests = (runtime, reason) => {
  runtime.pendingRequests->Map.forEach(pending => {
    clearTimeout(pending.timeoutId)
    pending.removeAbortListener()
    pending.reject(JsError.make(reason))
  })
  runtime.pendingRequests->Map.clear
  runtime.responseStoredBytes = 0
  runtime.responseAssemblyCount = 0
  runtime.activeRequests->Map.forEach(requests => {
    requests->Array.forEach(request => request.controller->AbortController.abort)
  })
  runtime.activeRequests->Map.clear
  runtime.settledRequests->Map.forEach(requests => requests->Set.clear)
  runtime.settledRequests->Map.clear
  runtime.requestHandler->RequestHandler.clear
}

let addActiveRequest = (runtime, id, controller, senderKey) => {
  let requests = runtime.activeRequests->Map.get(id)->Option.getOr([])
  runtime.activeRequests->Map.set(id, requests->Array.concat([{controller, senderKey}]))
}

let removeActiveRequest = (runtime, id, controller, senderKey) => {
  switch runtime.activeRequests->Map.get(id) {
  | Some(requests) => {
      let remaining = requests->Array.filter(request => {
        request.controller !== controller || request.senderKey !== senderKey
      })
      if remaining->Array.length === requests->Array.length {
        false
      } else {
        if remaining->Array.length === 0 {
          runtime.activeRequests->Map.delete(id)->ignore
        } else {
          runtime.activeRequests->Map.set(id, remaining)
        }
        true
      }
    }
  | None => false
  }
}

let cancelActiveRequests = (runtime, id, senderKey) => {
  switch runtime.activeRequests->Map.get(id) {
  | Some(requests) => {
      let matching = requests->Array.filter(request => request.senderKey === senderKey)
      let remaining = requests->Array.filter(request => request.senderKey !== senderKey)
      if remaining->Array.length === 0 {
        runtime.activeRequests->Map.delete(id)->ignore
      } else {
        runtime.activeRequests->Map.set(id, remaining)
      }
      matching->Array.forEach(request => request.controller->AbortController.abort)
    }
  | None => ()
  }
}

let settleActiveRequest = (runtime, id, controller, senderKey) => {
  if removeActiveRequest(runtime, id, controller, senderKey) {
    let settled = switch runtime.settledRequests->Map.get(senderKey) {
    | Some(settled) => settled
    | None => {
        let settled = Set.make()
        runtime.settledRequests->Map.set(senderKey, settled)
        settled
      }
    }
    settled->Set.add(id)
    cancelActiveRequests(runtime, id, senderKey)
    setTimeout(() => {
      settled->Set.delete(id)->ignore
      if settled->Set.size === 0 {
        runtime.settledRequests->Map.delete(senderKey)->ignore
      }
    }, 0)->ignore
    true
  } else {
    false
  }
}

let isRequestSettled = (runtime, id, senderKey) => {
  runtime.settledRequests
  ->Map.get(senderKey)
  ->Option.mapOr(false, settled => settled->Set.has(id))
}

let rejectInvalidResponse = (runtime, id) => {
  rejectPendingRequest(runtime, id, "Invalid response payload")
}

let resolveResponseChunk = (runtime, id, chunk) => {
  switch runtime.pendingRequests->Map.get(id) {
  | None => ()
  | Some(pending) =>
    try {
      let messageId = chunk->TransportMessage.Chunk.messageId
      let index = chunk->TransportMessage.Chunk.index
      let total = chunk->TransportMessage.Chunk.total
      let body = chunk->TransportMessage.Chunk.body
      let bodyBytes = body->MessageChunker.stringByteLength
      let maxChunks = MessageChunker.chunkCountLimit(
        ~maxMessageBytes=runtime.transport.maxMessageBytes,
        ~maxChunkBytes=runtime.transport.maxChunkBytes,
      )
      if (
        Type.typeof(Obj.magic(messageId)) !== #string ||
        messageId->Id.toString === "" ||
        !isSafeInteger(Obj.magic(index)) ||
        !isSafeInteger(Obj.magic(total)) ||
        Type.typeof(Obj.magic(body)) !== #string ||
        body === "" ||
        total <= 1 ||
        total > maxChunks ||
        index < 0 ||
        index >= total ||
        bodyBytes > runtime.transport.maxChunkBytes ||
        (index < total - 1 && bodyBytes < runtime.transport.maxChunkBytes - 3)
      ) {
        rejectInvalidResponse(runtime, id)
      } else {
        let assembly = switch pending.responseAssembly {
        | Some(assembly) => assembly
        | None => {
            if runtime.responseAssemblyCount >= runtime.transport.maxPendingRequests {
              JsError.throwWithMessage("Too many pending response assemblies")
            }
            let assembly = {messageId, total, bytes: 0, chunks: Map.make()}
            pending.responseAssembly = Some(assembly)
            runtime.responseAssemblyCount = runtime.responseAssemblyCount + 1
            assembly
          }
        }
        if (
          assembly.messageId !== messageId ||
          assembly.total !== total ||
          assembly.chunks->Map.has(index) ||
          assembly.bytes + bodyBytes > runtime.transport.maxMessageBytes ||
          runtime.responseStoredBytes + bodyBytes > runtime.transport.maxMessageBytes
        ) {
          rejectInvalidResponse(runtime, id)
        } else {
          assembly.chunks->Map.set(index, chunk)
          assembly.bytes = assembly.bytes + bodyBytes
          runtime.responseStoredBytes = runtime.responseStoredBytes + bodyBytes
          if assembly.chunks->Map.size === total {
            let chunks = []
            assembly.chunks->Map.forEach(chunk => chunks->Array.push(chunk)->ignore)
            let value = chunks->TransportMessage.reassembleChunks->JSON.parseOrThrow
            let normalized = value->MessageChunker.normalizeJson
            if normalized->MessageChunker.byteLength > runtime.transport.maxMessageBytes {
              rejectInvalidResponse(runtime, id)
            } else {
              switch takePendingRequest(runtime, id) {
              | Some(pending) => pending.resolve(normalized)
              | None => ()
              }
            }
          }
        }
      }
    } catch {
    | _ => rejectInvalidResponse(runtime, id)
    }
  }
}

let make:
  type sender extension. transport<sender, extension> => t<sender> =
  transport => {
    if (
      !isSafeInteger(Obj.magic(transport.requestTimeoutMs)) ||
      !isSafeInteger(Obj.magic(transport.maxMessageBytes)) ||
      !isSafeInteger(Obj.magic(transport.maxPendingRequests)) ||
      !isSafeInteger(Obj.magic(transport.maxChunkBytes)) ||
      transport.requestTimeoutMs <= 0 ||
      transport.maxMessageBytes <= 0 ||
      transport.maxPendingRequests <= 0 ||
      transport.maxChunkBytes < 4 ||
      transport.maxMessageBytes > 1_000_000_000 ||
      transport.maxChunkBytes > transport.maxMessageBytes ||
      transport.maxChunkBytes >= 4 &&
        MessageChunker.configuredChunkCount(
          ~maxMessageBytes=transport.maxMessageBytes,
          ~maxChunkBytes=transport.maxChunkBytes,
        ) >
        MessageChunker.maxChunksPerMessage ||
      transport.maxPendingRequests > 1_000_000
    ) {
      JsError.throwWithMessage("Runtime limits are invalid")
    }
    let transportCore: transportCore<sender> = {
      requestTimeoutMs: transport.requestTimeoutMs,
      maxMessageBytes: transport.maxMessageBytes,
      maxPendingRequests: transport.maxPendingRequests,
      maxChunkBytes: transport.maxChunkBytes,
      postMessage: transport.postMessage,
      addMessageListener: transport.addMessageListener,
      removeMessageListener: transport.removeMessageListener,
      addOpenListener: transport.addOpenListener,
      removeOpenListener: transport.removeOpenListener,
      addCloseListener: transport.addCloseListener,
      removeCloseListener: transport.removeCloseListener,
      isOpen: transport.isOpen,
      isCurrentSender: transport.isCurrentSender,
      senderKey: transport.senderKey,
      close: transport.close,
    }
    let initiallyOpen = transportCore.isOpen()
    let runtime = {
      transport: transportCore,
      pendingRequests: Map.make(),
      responseStoredBytes: 0,
      responseAssemblyCount: 0,
      activeRequests: Map.make(),
      settledRequests: Map.make(),
      requestHandler: RequestHandler.makeState(
        ~timeoutMs=transport.requestTimeoutMs,
        ~maxMessageBytes=transport.maxMessageBytes,
        ~maxPendingRequests=transport.maxPendingRequests,
        ~maxChunkBytes=transport.maxChunkBytes,
      ),
      messageHandlers: ref([]),
      inboundHandler: ref((_message, _sender) => ()),
      openListeners: ref([]),
      lifecycleCloseListeners: ref([]),
      reconnectListeners: ref([]),
      responseHandler: None,
      openHandler: None,
      closeHandler: None,
      hasOpened: initiallyOpen,
      connectionOpen: initiallyOpen,
      closed: false,
    }

    let responseHandler = (message, sender) => {
      if runtime.transport.isCurrentSender(sender) {
        try {
          switch (Obj.magic(message): protocolMessage) {
          | Success({id, value}) =>
            if !hasOwn(Obj.magic(message), "id") || !hasOwn(Obj.magic(message), "value") {
              rejectInvalidResponse(runtime, id)
            } else {
              try {
                let normalized = value->MessageChunker.normalizeJson
                if normalized->MessageChunker.byteLength > runtime.transport.maxMessageBytes {
                  rejectInvalidResponse(runtime, id)
                } else {
                  switch takePendingRequest(runtime, id) {
                  | Some(pending) => pending.resolve(normalized)
                  | None => ()
                  }
                }
              } catch {
              | _ => rejectInvalidResponse(runtime, id)
              }
            }
          | SuccessChunk({id, chunk}) => resolveResponseChunk(runtime, id, chunk)
          | Failure({id, message}) =>
            if (
              Type.typeof(Obj.magic(message)) === #string &&
                message->MessageChunker.stringByteLength <= runtime.transport.maxMessageBytes
            ) {
              rejectPendingRequest(runtime, id, message)
            } else {
              rejectInvalidResponse(runtime, id)
            }
          | Request(_) | Cancel(_) | Cast(_) => runtime.inboundHandler.contents(message, sender)
          }
        } catch {
        | _ => ()
        }
      }
    }
    let openHandler = () => {
      if !runtime.closed && !runtime.connectionOpen {
        runtime.connectionOpen = true
        if runtime.hasOpened {
          notifyListeners(runtime.reconnectListeners.contents)
        } else {
          runtime.hasOpened = true
          notifyListeners(runtime.openListeners.contents)
        }
      }
    }
    let closeHandler = reason => {
      clearPendingRequests(runtime, reason)
      if runtime.connectionOpen {
        runtime.connectionOpen = false
        notifyCloseListeners(runtime.lifecycleCloseListeners.contents, reason)
      }
    }

    runtime.responseHandler = Some(responseHandler)
    runtime.openHandler = Some(openHandler)
    runtime.closeHandler = Some(closeHandler)
    transportCore.addMessageListener(responseHandler)
    transportCore.addOpenListener(openHandler)
    transportCore.addCloseListener(closeHandler)
    runtime
  }

let sendRequest = (
  runtime,
  message: TransportMessage.t<'response>,
  ~signal=?,
  ~assemblyId=None,
): Promise.t<'response> => {
  if runtime.pendingRequests->Map.size >= runtime.transport.maxPendingRequests {
    rejectedPromise("Too many pending requests")
  } else {
    let id = Id.make()
    Promise.make((resolve, reject) => {
      if signal->Option.mapOr(false, AbortSignal.aborted) {
        reject(JsError.make("Request aborted"))
      } else {
        let abortHandler = () => {
          rejectPendingRequest(runtime, id, "Request aborted", ~notifyRemote=true, ~assemblyId)
        }
        let removeAbortListener = switch signal {
        | Some(signal) => {
            AbortSignal.addEventListener(signal, "abort", abortHandler)
            () => AbortSignal.removeEventListener(signal, "abort", abortHandler)
          }
        | None => () => ()
        }
        let timeoutId = setTimeout(() => {
          rejectPendingRequest(runtime, id, "Request timed out", ~notifyRemote=true, ~assemblyId)
        }, runtime.transport.requestTimeoutMs)
        runtime.pendingRequests->Map.set(
          id,
          {
            resolve: value => resolve(Obj.magic(value)),
            reject,
            timeoutId,
            removeAbortListener,
            responseAssembly: None,
          },
        )

        try {
          sendProtocolMessage(runtime, Request({id, message: Obj.magic(message)}))
        } catch {
        | error => rejectPendingRequest(runtime, id, exceptionMessage(error))
        }
      }
    })
  }
}

let rec sendChunks = async (runtime, chunks: array<Obj.t>, index, assemblyId, ~signal=?): Obj.t => {
  switch chunks->Array.get(index) {
  | None => JsError.throwWithMessage("Chunked message did not contain a final chunk")
  | Some(chunk) =>
    if index === chunks->Array.length - 1 {
      (await sendRequest(runtime, Obj.magic(chunk), ~signal?, ~assemblyId))->Obj.magic
    } else {
      (await sendRequest(runtime, Obj.magic(chunk), ~signal?, ~assemblyId))->ignore
      await sendChunks(runtime, chunks, index + 1, assemblyId, ~signal?)
    }
  }
}

let sendChunkedMessage = (runtime, chunks, assemblyId, ~signal=?) => {
  let removeAbortListener = switch (signal, assemblyId) {
  | (Some(signal), Some(assemblyId)) if !(signal->AbortSignal.aborted) => {
      let abortHandler = () => sendCancellation(runtime, None, Some(assemblyId))
      AbortSignal.addEventListener(signal, "abort", abortHandler)
      () => AbortSignal.removeEventListener(signal, "abort", abortHandler)
    }
  | _ => () => ()
  }
  sendChunks(runtime, chunks, 0, assemblyId, ~signal?)
  ->Promise.thenResolve(value => {
    removeAbortListener()
    value
  })
  ->Promise.catch(error => {
    removeAbortListener()
    Promise.reject(error)
  })
}

let sendMessage:
  type sender response. (
    t<sender>,
    Types.message<response>,
    ~signal: AbortSignal.t=?,
  ) => Promise.t<response> =
  (runtime, message, ~signal=?) => {
    try {
      let normalizedMessage = message->MessageChunker.normalizeJson
      let messageBytes = normalizedMessage->MessageChunker.byteLength
      if messageBytes > runtime.transport.maxMessageBytes {
        rejectedPromise("Message exceeds maxMessageBytes")
      } else if (
        normalizedMessage->MessageChunker.shouldBeChunked(~size=runtime.transport.maxChunkBytes)
      ) {
        let chunks = TransportMessage.createChunks(
          normalizedMessage,
          ~size=runtime.transport.maxChunkBytes,
        )
        let assemblyId = chunks->Array.get(0)->Option.flatMap(TransportMessage.messageId)
        sendChunkedMessage(runtime, Obj.magic(chunks), assemblyId, ~signal?)->Promise.thenResolve(
          Obj.magic,
        )
      } else {
        sendRequest(runtime, TransportMessage.UserMessage(Obj.magic(normalizedMessage)), ~signal?)
      }
    } catch {
    | error => Promise.reject(error)
    }
  }

let castTransportMessage = (runtime, message) => {
  try {
    sendProtocolMessage(
      runtime,
      (Cast({id: Id.make(), message: Obj.magic(message)}): protocolMessage),
    )
  } catch {
  | error => Console.error2("Failed to cast message:", error)
  }
}

let sendResponse = (runtime, sender, message) => {
  if !runtime.closed && runtime.transport.isCurrentSender(sender) {
    try {
      let boundedMessage = try {
        switch message {
        | Success({id, value}) =>
          let normalizedValue = value->MessageChunker.normalizeJson
          if normalizedValue->MessageChunker.byteLength > runtime.transport.maxMessageBytes {
            (Failure({id, message: "Response exceeds maxMessageBytes"}): protocolMessage)
          } else {
            (Success({id, value: normalizedValue}): protocolMessage)
          }
        | Failure({id, message})
          if message->MessageChunker.stringByteLength > runtime.transport.maxMessageBytes =>
          (Failure({id, message: "Remote error exceeds maxMessageBytes"}): protocolMessage)
        | SuccessChunk(_) | Failure(_) | Request(_) | Cancel(_) | Cast(_) => message
        }
      } catch {
      | _ =>
        switch message {
        | Success({id, value: _}) | Failure({id, message: _}) =>
          (Failure({id, message: "Response could not be serialized"}): protocolMessage)
        | SuccessChunk(_) | Request(_) | Cancel(_) | Cast(_) => message
        }
      }
      let sendCloneFailure = id => {
        try {
          sendProtocolMessage(
            runtime,
            (Failure({id, message: "Response could not be cloned"}): protocolMessage),
          )
        } catch {
        | _ => ()
        }
      }
      switch boundedMessage {
      | Success({id, value})
        if value->MessageChunker.byteLength > runtime.transport.maxChunkBytes =>
        try {
          value
          ->TransportMessage.createRawChunks(~size=runtime.transport.maxChunkBytes)
          ->Array.forEach(chunk => {
            sendProtocolMessage(runtime, (SuccessChunk({id, chunk}): protocolMessage))
          })
        } catch {
        | _ => sendCloneFailure(id)
        }
      | Success(_) | SuccessChunk(_) | Failure(_) | Request(_) | Cancel(_) | Cast(_) =>
        try {
          sendProtocolMessage(runtime, boundedMessage)
        } catch {
        | _ =>
          switch boundedMessage {
          | Success({id, value: _}) => sendCloneFailure(id)
          | SuccessChunk(_) | Failure(_) | Request(_) | Cancel(_) | Cast(_) => ()
          }
        }
      }
    } catch {
    | _ => ()
    }
  }
}

let inboundRequestCount = (runtime, senderKey) => {
  let count = ref(0)
  runtime.activeRequests->Map.forEach(requests => {
    if requests->Array.some(request => request.senderKey === senderKey) {
      count := count.contents + 1
    }
  })
  count.contents
}

let isActiveRequest = (runtime, id, senderKey) => {
  runtime.activeRequests
  ->Map.get(id)
  ->Option.mapOr(false, requests =>
    requests->Array.some(request => request.senderKey === senderKey)
  )
}

let cast:
  type sender response. (t<sender>, Types.message<response>) => unit =
  (runtime, message) => {
    let normalizedMessage = message->MessageChunker.normalizeJson
    let messageBytes = normalizedMessage->MessageChunker.byteLength
    if messageBytes > runtime.transport.maxMessageBytes {
      JsError.throwWithMessage("Message exceeds maxMessageBytes")
    } else if (
      normalizedMessage->MessageChunker.shouldBeChunked(~size=runtime.transport.maxChunkBytes)
    ) {
      TransportMessage.createChunks(
        normalizedMessage,
        ~size=runtime.transport.maxChunkBytes,
      )->Array.forEach(castTransportMessage(runtime, _))
    } else {
      castTransportMessage(runtime, TransportMessage.UserMessage(Obj.magic(normalizedMessage)))
    }
  }

type deferredHandlerResponse = {
  promise: Promise.t<Obj.t>,
  controller: AbortController.t,
}

type immediateHandlerResponse =
  | Value(Obj.t)
  | Error(string)

let dispatchRequestHandlers = (runtime, id, senderKey, message, sender) => {
  let deferred = []
  let immediate = ref(None)
  runtime.messageHandlers.contents->Array.forEach(registered => {
    if immediate.contents->Option.isNone {
      let controller = AbortController.make()
      addActiveRequest(runtime, id, controller, senderKey)
      try {
        switch registered(message, sender, Some(controller->AbortController.signal)) {
        | Response.RespondNow(value) =>
          if settleActiveRequest(runtime, id, controller, senderKey) {
            immediate := Some(Value(value))
          }
        | Response.RespondLater(promise) => deferred->Array.push({promise, controller})->ignore
        | Response.NoResponse => removeActiveRequest(runtime, id, controller, senderKey)->ignore
        }
      } catch {
      | error =>
        if settleActiveRequest(runtime, id, controller, senderKey) {
          immediate := Some(Error(exceptionMessage(error)))
        }
      }
    }
  })

  switch immediate.contents {
  | Some(Value(value)) => Response.RespondNow(value)
  | Some(Error(message)) => JsError.throwWithMessage(message)
  | None if deferred->Array.length === 0 => Response.NoResponse
  | None =>
    Response.RespondLater(
      Promise.make((resolve, reject) => {
        deferred->Array.forEach(response => {
          response.promise
          ->Promise.thenResolve(
            value => {
              if settleActiveRequest(runtime, id, response.controller, senderKey) {
                resolve(value)
              }
            },
          )
          ->Promise.catch(
            error => {
              if settleActiveRequest(runtime, id, response.controller, senderKey) {
                reject(error)
              }
              Promise.resolve()
            },
          )
          ->ignore
        })
      }),
    )
  }
}

let dispatchCastHandlers = (runtime, message, sender) => {
  runtime.messageHandlers.contents->Array.forEach(registered => {
    try {
      switch registered(message, sender, None) {
      | Response.RespondLater(promise) =>
        promise->Promise.thenResolve(_ => ())->Promise.catch(_ => Promise.resolve())->ignore
      | Response.RespondNow(_) | Response.NoResponse => ()
      }
    } catch {
    | _ => ()
    }
  })
  Response.none
}

let handleInboundProtocol = (runtime, rawMessage, sender) => {
  if runtime.transport.isCurrentSender(sender) {
    try {
      let senderKey = runtime.transport.senderKey(sender)
      switch (Obj.magic(rawMessage): protocolMessage) {
      | Request({id, message: _}) if isRequestSettled(runtime, id, senderKey) => ()
      | Request({id, message: _}) if isActiveRequest(runtime, id, senderKey) =>
        sendResponse(runtime, sender, Failure({id, message: "Duplicate request"}))
      | Request({id, message: _})
        if inboundRequestCount(runtime, senderKey) >= runtime.transport.maxPendingRequests =>
        sendResponse(runtime, sender, Failure({id, message: "Too many pending requests"}))
      | Request({id, message}) =>
        try {
          switch RequestHandler.make(
            runtime.requestHandler,
            ~userHandler=(message, sender, _signal) =>
              dispatchRequestHandlers(
                runtime,
                id,
                senderKey,
                Obj.magic(message),
                sender,
              )->Obj.magic,
            Obj.magic(message),
            sender,
            senderKey,
            id,
            None,
          ) {
          | Response.RespondNow(value) => sendResponse(runtime, sender, Success({id, value}))
          | Response.RespondLater(promise) =>
            promise
            ->Promise.thenResolve(value => sendResponse(runtime, sender, Success({id, value})))
            ->Promise.catch(error => {
              sendResponse(runtime, sender, Failure({id, message: exceptionMessage(error)}))
              Promise.resolve()
            })
            ->ignore
          | Response.NoResponse => ()
          }
        } catch {
        | error => sendResponse(runtime, sender, Failure({id, message: exceptionMessage(error)}))
        }
      | Cancel({requestId, assemblyId}) => {
          requestId->Option.forEach(id => cancelActiveRequests(runtime, id, senderKey))
          assemblyId->Option.forEach(messageId =>
            RequestHandler.cancel(runtime.requestHandler, senderKey, messageId)
          )
        }
      | Cast({id, message}) =>
        try {
          RequestHandler.make(
            runtime.requestHandler,
            ~userHandler=(message, sender, _signal) =>
              dispatchCastHandlers(runtime, Obj.magic(message), sender)->Obj.magic,
            Obj.magic(message),
            sender,
            senderKey,
            id,
            None,
          )->ignore
        } catch {
        | _ => ()
        }
      | Success(_) | SuccessChunk(_) | Failure(_) => ()
      }
    } catch {
    | _ => ()
    }
  }
}

module OnMessage = {
  let addListener:
    type sender response. (
      t<sender>,
      (Types.message<response>, sender, option<AbortSignal.t>) => Response.t<response>,
    ) => unit =
    (runtime, userHandler) => {
      if runtime.closed {
        JsError.throwWithMessage("Runtime is closed")
      }
      let handler = Obj.magic(userHandler)
      if !(runtime.messageHandlers.contents->Array.some(registered => registered === handler)) {
        runtime.messageHandlers := runtime.messageHandlers.contents->Array.concat([handler])
        runtime.inboundHandler :=
          ((message, sender) => handleInboundProtocol(runtime, message, sender))
      }
    }

  let removeListener:
    type sender response. (
      t<sender>,
      (Types.message<response>, sender, option<AbortSignal.t>) => Response.t<response>,
    ) => unit =
    (runtime, userHandler) => {
      let handler = Obj.magic(userHandler)
      let previousLength = runtime.messageHandlers.contents->Array.length
      runtime.messageHandlers :=
        runtime.messageHandlers.contents->Array.filter(registered => registered !== handler)
      if runtime.messageHandlers.contents->Array.length === previousLength {
        Console.warn("Handler not found - was it already removed or never added?")
      } else if runtime.messageHandlers.contents->Array.length === 0 {
        runtime.inboundHandler := ((_message, _sender) => ())
      }
    }
}

let isContextValid = runtime => !runtime.closed && runtime.transport.isOpen()

let subscribe = (listeners, listener) => {
  listeners := listeners.contents->Array.concat([listener])
  let subscribed = ref(true)
  () => {
    if subscribed.contents {
      subscribed := false
      removeFirst(listeners, listener)
    }
  }
}

let onOpen = (runtime, listener) => subscribe(runtime.openListeners, listener)
let onClose = (runtime, listener) => subscribe(runtime.lifecycleCloseListeners, listener)
let onReconnect = (runtime, listener) => subscribe(runtime.reconnectListeners, listener)

let close = runtime => {
  if !runtime.closed {
    runtime.closed = true
    clearPendingRequests(runtime, "Runtime closed")
    let closeListeners = runtime.connectionOpen ? runtime.lifecycleCloseListeners.contents : []
    runtime.connectionOpen = false
    runtime.requestHandler->RequestHandler.clear
    runtime.messageHandlers := []
    runtime.inboundHandler := ((_message, _sender) => ())
    switch runtime.responseHandler {
    | Some(handler) => runtime.transport.removeMessageListener(handler)
    | None => ()
    }
    switch runtime.openHandler {
    | Some(handler) => runtime.transport.removeOpenListener(handler)
    | None => ()
    }
    switch runtime.closeHandler {
    | Some(handler) => runtime.transport.removeCloseListener(handler)
    | None => ()
    }
    runtime.openListeners := []
    runtime.lifecycleCloseListeners := []
    runtime.reconnectListeners := []
    runtime.transport.close()
    notifyCloseListeners(closeListeners, "Runtime closed")
  }
}
