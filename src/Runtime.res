/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

module type RuntimeBindings = {
  type sender
  let requestTimeoutMs: int
  let postMessage: 'a => result<unit, string>
  module OnMessage: {
    let addListener: (('a, sender) => unit) => unit
    let removeListener: (('a, sender) => unit) => unit
  }
  module OnClose: {
    let addListener: (string => unit) => unit
  }
  let isOpen: unit => bool
  let close: unit => unit
}

type protocolMessage =
  | Request({id: Id.t, message: Obj.t})
  | Cast(Obj.t)
  | Success({id: Id.t, value: Obj.t})
  | Failure({id: Id.t, message: string})

type pendingRequest = {
  resolve: Obj.t => unit,
  reject: JsError.t => unit,
  timeoutId: timeoutId,
}

@val external errorToString: 'a => string = "String"

let exceptionMessage = error => {
  error->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(errorToString(error))
}

module Make = (Bindings: RuntimeBindings) => {
  let pendingRequests: Map.t<Id.t, pendingRequest> = Map.make()
  let handlerToWrapped: HandlerMap.t = HandlerMap.make()

  let sendProtocolMessage = message => {
    switch Bindings.postMessage(message) {
    | Ok() => ()
    | Error(message) => JsError.throwWithMessage(message)
    }
  }

  let rejectPendingRequest = (id, message) => {
    switch pendingRequests->Map.get(id) {
    | Some(pending) => {
        clearTimeout(pending.timeoutId)
        pendingRequests->Map.delete(id)->ignore
        pending.reject(JsError.make(message))
      }
    | None => ()
    }
  }

  let responseHandler = (message, _sender) => {
    switch (Obj.magic(message): protocolMessage) {
    | Success({id, value}) =>
      switch pendingRequests->Map.get(id) {
      | Some(pending) => {
          clearTimeout(pending.timeoutId)
          pendingRequests->Map.delete(id)->ignore
          pending.resolve(value)
        }
      | None => ()
      }
    | Failure({id, message}) => rejectPendingRequest(id, message)
    | Request(_) | Cast(_) => ()
    }
  }

  let closeHandler = reason => {
    pendingRequests->Map.forEach(pending => {
      clearTimeout(pending.timeoutId)
      pending.reject(JsError.make(reason))
    })
    pendingRequests->Map.clear
  }

  Bindings.OnMessage.addListener(responseHandler)
  Bindings.OnClose.addListener(closeHandler)

  let sendRequest = (message: TransportMessage.t<'response>): Promise.t<'response> => {
    let id = Id.make()
    Promise.make((resolve, reject) => {
      let timeoutId = setTimeout(() => {
        rejectPendingRequest(id, "Request timed out")
      }, Bindings.requestTimeoutMs)
      pendingRequests->Map.set(
        id,
        {
          resolve: value => resolve(Obj.magic(value)),
          reject,
          timeoutId,
        },
      )

      try {
        sendProtocolMessage(Request({id, message: Obj.magic(message)}))
      } catch {
      | error => rejectPendingRequest(id, exceptionMessage(error))
      }
    })
  }

  let rec sendChunks = async (chunks: array<Obj.t>, index): Obj.t => {
    switch chunks->Array.get(index) {
    | None => JsError.throwWithMessage("Chunked message did not contain a final chunk")
    | Some(chunk) =>
      if index === chunks->Array.length - 1 {
        (await sendRequest(Obj.magic(chunk)))->Obj.magic
      } else {
        (await sendRequest(Obj.magic(chunk)))->ignore
        await sendChunks(chunks, index + 1)
      }
    }
  }

  let sendMessage:
    type a. Types.message<a> => Promise.t<a> =
    message => {
      if message->MessageChunker.shouldBeChunked {
        sendChunks(Obj.magic(TransportMessage.createChunks(message)), 0)->Promise.thenResolve(
          Obj.magic,
        )
      } else {
        sendRequest(TransportMessage.UserMessage(message))
      }
    }

  let castTransportMessage = message => {
    try {
      sendProtocolMessage(Cast(Obj.magic(message)))
    } catch {
    | error => Console.error2("Failed to cast message:", error)
    }
  }

  let cast:
    type a. Types.message<a> => unit =
    message => {
      if message->MessageChunker.shouldBeChunked {
        TransportMessage.createChunks(message)->Array.forEach(castTransportMessage)
      } else {
        castTransportMessage(TransportMessage.UserMessage(message))
      }
    }

  module OnMessage = {
    let addListener:
      type a. ((Types.message<a>, Bindings.sender) => Response.t<a>) => unit =
      userHandler => {
        let messageHandler = (protocolMessage, sender) => {
          let handleTransportMessage = transportMessage => {
            RequestHandler.make(~userHandler, transportMessage, sender)
          }

          switch (Obj.magic(protocolMessage): protocolMessage) {
          | Request({id, message}) =>
            try {
              switch handleTransportMessage(Obj.magic(message)) {
              | Response.RespondNow(value) =>
                sendProtocolMessage(Success({id, value: Obj.magic(value)}))
              | Response.RespondLater(promise) =>
                promise
                ->Promise.thenResolve(value => {
                  sendProtocolMessage(Success({id, value: Obj.magic(value)}))
                })
                ->Promise.catch(error => {
                  sendProtocolMessage(
                    (Failure({id, message: exceptionMessage(error)}): protocolMessage),
                  )
                  Promise.resolve()
                })
                ->ignore
              | Response.NoResponse => ()
              }
            } catch {
            | error =>
              sendProtocolMessage(
                (Failure({id, message: exceptionMessage(error)}): protocolMessage),
              )
            }
          | Cast(message) =>
            try {
              switch handleTransportMessage(Obj.magic(message)) {
              | Response.RespondLater(promise) =>
                promise
                ->Promise.thenResolve(_ => ())
                ->Promise.catch(_ => Promise.resolve())
                ->ignore
              | Response.RespondNow(_) | Response.NoResponse => ()
              }
            } catch {
            | _ => ()
            }
          | Success(_) | Failure(_) => ()
          }
        }

        HandlerMap.set(handlerToWrapped, userHandler, messageHandler)
        Bindings.OnMessage.addListener(messageHandler)
      }

    let removeListener:
      type a. ((Types.message<a>, Bindings.sender) => Response.t<a>) => unit =
      userHandler => {
        switch HandlerMap.get(handlerToWrapped, userHandler) {
        | Some(wrappedHandler) => {
            Bindings.OnMessage.removeListener(wrappedHandler)
            HandlerMap.delete(handlerToWrapped, userHandler)
          }
        | None => Console.warn("Handler not found - was it already removed or never added?")
        }
      }
  }

  let isContextValid = Bindings.isOpen
  let close = () => {
    closeHandler("Runtime closed")
    Bindings.close()
  }
}
