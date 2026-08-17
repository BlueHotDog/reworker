/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

let marker = "@bluehotdog/reworker/window/v1"

@scope("Number") @val external isSafeInteger: Obj.t => bool = "isSafeInteger"
@scope("Object") @val external hasOwn: (Obj.t, string) => bool = "hasOwn"
@val external errorToString: 'a => string = "String"
@get external pageTransitionPersisted: Obj.t => bool = "persisted"

type bootstrapMessage = {
  marker: string,
  kind: string,
  channel: string,
  connectionId: string,
}

type portMessage = {
  marker: string,
  kind: string,
  channel: string,
  connectionId: string,
  payload?: Obj.t,
  reason?: string,
}

type connection = {
  handshakeId: string,
  session: Runtime.session<unit>,
  port: MessagePort.t,
  clearReadinessTimeout: unit => unit,
  cleanup: unit => unit,
}

let exceptionMessage = error =>
  error->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(errorToString(error))

let validateEndpointConfig = (~origin, ~originName, ~channel, ~maxChunkBytes) => {
  if origin === "" || origin === "*" {
    JsError.throwWithMessage(`${originName} must be an explicit origin`)
  }
  if channel === "" {
    JsError.throwWithMessage("channel must not be empty")
  }
  if !isSafeInteger(Obj.magic(maxChunkBytes)) || maxChunkBytes <= 0 {
    JsError.throwWithMessage("maxChunkBytes is invalid")
  }
}

let closePortSafely = port => {
  try {
    MessagePort.close(port)
  } catch {
  | _ => ()
  }
}

let postPortMessage = (port, ~kind, ~channel, ~connectionId, ~payload=?, ~reason=?) => {
  let message: portMessage = {marker, kind, channel, connectionId, ?payload, ?reason}
  MessagePort.postMessage(port, message)
}

let readPortMessage = (value, ~channel, ~connectionId) => {
  try {
    let message: portMessage = Obj.magic(value)
    if (
      Type.typeof(Obj.magic(message.marker)) === #string &&
      message.marker === marker &&
      Type.typeof(Obj.magic(message.kind)) === #string &&
      Type.typeof(Obj.magic(message.channel)) === #string &&
      message.channel === channel &&
      Type.typeof(Obj.magic(message.connectionId)) === #string &&
      message.connectionId === connectionId
    ) {
      Some(message)
    } else {
      None
    }
  } catch {
  | _ => None
  }
}

let readBootstrapMessage = (value, ~channel) => {
  try {
    let message: bootstrapMessage = Obj.magic(value)
    if (
      Type.typeof(Obj.magic(message.marker)) === #string &&
      message.marker === marker &&
      Type.typeof(Obj.magic(message.kind)) === #string &&
      message.kind === "connect" &&
      Type.typeof(Obj.magic(message.channel)) === #string &&
      message.channel === channel &&
      Type.typeof(Obj.magic(message.connectionId)) === #string &&
      message.connectionId !== ""
    ) {
      Some(message)
    } else {
      None
    }
  } catch {
  | _ => None
  }
}

let makeConnection = (
  ~handshakeId,
  ~session,
  ~port,
  ~onMessage,
  ~onMessageError,
  ~timeoutId=None,
) => {
  let cleaned = ref(false)
  let timeout = ref(timeoutId)
  let clearReadinessTimeout = () => {
    timeout.contents->Option.forEach(clearTimeout)
    timeout := None
  }
  let cleanup = () => {
    if !cleaned.contents {
      cleaned := true
      clearReadinessTimeout()
      try {
        MessagePort.removeEventListener(port, "message", onMessage)
      } catch {
      | _ => ()
      }
      try {
        MessagePort.removeEventListener(port, "messageerror", onMessageError)
      } catch {
      | _ => ()
      }
      closePortSafely(port)
    }
  }
  {handshakeId, session, port, clearReadinessTimeout, cleanup}
}

let installConnection = (connection, onMessage, onMessageError) => {
  MessagePort.addEventListener(connection.port, "message", onMessage)
  MessagePort.addEventListener(connection.port, "messageerror", onMessageError)
  MessagePort.start(connection.port)
}

let postConnectionData = (connection, ~channel, payload) => {
  try {
    postPortMessage(
      connection.port,
      ~kind="data",
      ~channel,
      ~connectionId=connection.handshakeId,
      ~payload,
    )
    Ok()
  } catch {
  | error => Error(exceptionMessage(error))
  }
}

let closeConnection = (connection, ~channel, ~reason, ~notifyRemote) => {
  if notifyRemote {
    try {
      postPortMessage(
        connection.port,
        ~kind="close",
        ~channel,
        ~connectionId=connection.handshakeId,
        ~reason,
      )
    } catch {
    | _ => ()
    }
  }
  connection.cleanup()
}

module Parent = {
  type config<'targetWindow> = {
    targetWindow: 'targetWindow,
    targetOrigin: string,
    channel: string,
    subscribeLoad: (unit => unit) => unit => unit,
    connectionTimeoutMs: int,
    maxChunkBytes: int,
  }

  type state = Idle | Connecting(connection) | Open(connection) | Closed

  let make = config => {
    validateEndpointConfig(
      ~origin=config.targetOrigin,
      ~originName="targetOrigin",
      ~channel=config.channel,
      ~maxChunkBytes=config.maxChunkBytes,
    )
    if !isSafeInteger(Obj.magic(config.connectionTimeoutMs)) || config.connectionTimeoutMs <= 0 {
      JsError.throwWithMessage("connectionTimeoutMs is invalid")
    }

    let state = ref(Idle)

    let postMessage = payload => {
      switch state.contents {
      | Open(connection) => postConnectionData(connection, ~channel=config.channel, payload)
      | Idle | Connecting(_) => Error("Window transport is not connected")
      | Closed => Error("Window transport is closed")
      }
    }

    let start = (~beginSession) => {
      let startConnection = ref(() => ())

      let disconnectSession = (session, reason, ~notifyRemote) => {
        let current = switch state.contents {
        | Connecting(connection) | Open(connection) if connection.session === session =>
          Some(connection)
        | Idle | Connecting(_) | Open(_) | Closed => None
        }
        current->Option.forEach(connection => {
          state := Idle
          closeConnection(connection, ~channel=config.channel, ~reason, ~notifyRemote)
          connection.session.disconnected(reason)
        })
      }

      let commitClosed = () => {
        let current = switch state.contents {
        | Connecting(connection) | Open(connection) => Some(connection)
        | Idle | Closed => None
        }
        state := Closed
        current
      }

      startConnection :=
        (
          () => {
            switch state.contents {
            | Closed => ()
            | Idle => {
                let connectionId = Id.make()->Id.toString
                let channel = MessageChannel.make()
                let port = MessageChannel.port1(channel)
                let session = beginSession()
                let onMessage = event => {
                  switch state.contents {
                  | Connecting(connection) | Open(connection) if connection.session === session =>
                    switch readPortMessage(
                      MessageEvent.data(event),
                      ~channel=config.channel,
                      ~connectionId,
                    ) {
                    | Some(message) if message.kind === "ready" =>
                      switch state.contents {
                      | Connecting(current) if current.session === session => {
                          current.clearReadinessTimeout()
                          state := Open(current)
                          current.session.opened()
                        }
                      | Idle | Connecting(_) | Open(_) | Closed => ()
                      }
                    | Some(message)
                      if message.kind === "data" && hasOwn(Obj.magic(message), "payload") =>
                      switch state.contents {
                      | Open(current) if current.session === session =>
                        current.session.message(
                          message.payload->Option.getOr(Obj.magic(undefined)),
                          (),
                        )
                      | Idle | Connecting(_) | Open(_) | Closed => ()
                      }
                    | Some(message)
                      if message.kind === "close" &&
                      hasOwn(Obj.magic(message), "reason") &&
                      Type.typeof(Obj.magic(message.reason)) === #string =>
                      disconnectSession(
                        session,
                        message.reason->Option.getOr("Remote endpoint closed"),
                        ~notifyRemote=false,
                      )
                    | Some(_) | None =>
                      disconnectSession(
                        session,
                        "Received an invalid port message",
                        ~notifyRemote=true,
                      )
                    }
                  | Idle | Connecting(_) | Open(_) | Closed => ()
                  }
                }
                let onMessageError = _event =>
                  disconnectSession(
                    session,
                    "Message port could not deserialize a value",
                    ~notifyRemote=true,
                  )
                let timeoutId = setTimeout(() => {
                  switch state.contents {
                  | Connecting(connection) if connection.session === session =>
                    disconnectSession(
                      session,
                      "Window transport readiness timed out",
                      ~notifyRemote=true,
                    )
                  | Idle | Connecting(_) | Open(_) | Closed => ()
                  }
                }, config.connectionTimeoutMs)
                let connection = makeConnection(
                  ~handshakeId=connectionId,
                  ~session,
                  ~port,
                  ~onMessage,
                  ~onMessageError,
                  ~timeoutId=Some(timeoutId),
                )
                switch state.contents {
                | Idle => {
                    state := Connecting(connection)
                    switch state.contents {
                    | Connecting(current) if current.session === session =>
                      try {
                        installConnection(connection, onMessage, onMessageError)
                        let bootstrap: bootstrapMessage = {
                          marker,
                          kind: "connect",
                          channel: config.channel,
                          connectionId,
                        }
                        BrowserWindow.postMessage(
                          Obj.magic(config.targetWindow),
                          bootstrap,
                          config.targetOrigin,
                          [MessageChannel.port2(channel)],
                        )
                      } catch {
                      | error =>
                        disconnectSession(session, exceptionMessage(error), ~notifyRemote=false)
                      }
                    | Idle | Connecting(_) | Open(_) | Closed => connection.cleanup()
                    }
                  }
                | Connecting(_) | Open(_) | Closed => {
                    connection.cleanup()
                    closePortSafely(MessageChannel.port2(channel))
                    session.disconnected("Window connection setup was abandoned")
                  }
                }
              }
            | Connecting(_) | Open(_) => ()
            }
          }
        )

      let onLoad = () => {
        let currentSession = switch state.contents {
        | Connecting(connection) | Open(connection) => Some(connection.session)
        | Idle | Closed => None
        }
        currentSession->Option.forEach(session =>
          disconnectSession(session, "Iframe reloaded", ~notifyRemote=true)
        )
        switch state.contents {
        | Closed => ()
        | Idle => startConnection.contents()
        | Connecting(_) | Open(_) => ()
        }
      }

      let removeLoadListener = try {
        config.subscribeLoad(onLoad)
      } catch {
      | error => {
          let current = commitClosed()
          // No disposer exists on this path. subscribeLoad must undo registration before throwing.
          current->Option.forEach(connection => {
            connection.cleanup()
            connection.session.disconnected(exceptionMessage(error))
          })
          JsError.throw(Obj.magic(error))
        }
      }
      try {
        startConnection.contents()
      } catch {
      | error => {
          let current = commitClosed()
          try {
            removeLoadListener()
          } catch {
          | _ => ()
          }
          current->Option.forEach(connection => {
            connection.cleanup()
            connection.session.disconnected(exceptionMessage(error))
          })
          JsError.throw(Obj.magic(error))
        }
      }

      let tornDown = ref(false)
      () => {
        if !tornDown.contents {
          tornDown := true
          let current = switch state.contents {
          | Connecting(connection) | Open(connection) => Some(connection)
          | Idle | Closed => None
          }
          state := Closed
          try {
            removeLoadListener()
          } catch {
          | _ => ()
          }
          current->Option.forEach(connection => {
            closeConnection(
              connection,
              ~channel=config.channel,
              ~reason="Window transport closed",
              ~notifyRemote=true,
            )
          })
        }
      }
    }

    Runtime.makeTransport(~postMessage, ~start, ~maxChunkBytes=config.maxChunkBytes)
  }
}

module Child = {
  type config<'parentWindow> = {
    parentWindow: 'parentWindow,
    parentOrigin: string,
    channel: string,
    maxChunkBytes: int,
  }

  type state = Idle | Open(connection) | Closed

  let make = config => {
    validateEndpointConfig(
      ~origin=config.parentOrigin,
      ~originName="parentOrigin",
      ~channel=config.channel,
      ~maxChunkBytes=config.maxChunkBytes,
    )

    let state = ref(Idle)

    let postMessage = payload => {
      switch state.contents {
      | Open(connection) => postConnectionData(connection, ~channel=config.channel, payload)
      | Idle => Error("Window transport is not connected")
      | Closed => Error("Window transport is closed")
      }
    }

    let start = (~beginSession) => {
      let disconnectSession = (session, reason, ~notifyRemote) => {
        switch state.contents {
        | Open(connection) if connection.session === session => {
            state := Idle
            closeConnection(connection, ~channel=config.channel, ~reason, ~notifyRemote)
            connection.session.disconnected(reason)
          }
        | Idle | Open(_) | Closed => ()
        }
      }

      let onBootstrapMessage = event => {
        if (
          MessageEvent.origin(event) === config.parentOrigin &&
            MessageEvent.source(event) === Obj.magic(config.parentWindow)
        ) {
          switch readBootstrapMessage(MessageEvent.data(event), ~channel=config.channel) {
          | Some(bootstrap) =>
            switch MessageEvent.ports(event)->Array.get(0) {
            | Some(port) => {
                let previousSession = switch state.contents {
                | Open(connection) => Some(connection.session)
                | Idle | Closed => None
                }
                previousSession->Option.forEach(session =>
                  disconnectSession(session, "Parent replaced the connection", ~notifyRemote=false)
                )
                switch state.contents {
                | Closed => closePortSafely(port)
                | Idle => {
                    let connectionId = bootstrap.connectionId
                    let session = beginSession()
                    let onMessage = portEvent => {
                      switch state.contents {
                      | Open(connection) if connection.session === session =>
                        switch readPortMessage(
                          MessageEvent.data(portEvent),
                          ~channel=config.channel,
                          ~connectionId,
                        ) {
                        | Some(message)
                          if message.kind === "data" && hasOwn(Obj.magic(message), "payload") =>
                          connection.session.message(
                            message.payload->Option.getOr(Obj.magic(undefined)),
                            (),
                          )
                        | Some(message)
                          if message.kind === "close" &&
                          hasOwn(Obj.magic(message), "reason") &&
                          Type.typeof(Obj.magic(message.reason)) === #string =>
                          disconnectSession(
                            session,
                            message.reason->Option.getOr("Remote endpoint closed"),
                            ~notifyRemote=false,
                          )
                        | Some(_) | None =>
                          disconnectSession(
                            session,
                            "Received an invalid port message",
                            ~notifyRemote=true,
                          )
                        }
                      | Idle | Open(_) | Closed => ()
                      }
                    }
                    let onMessageError = _event =>
                      disconnectSession(
                        session,
                        "Message port could not deserialize a value",
                        ~notifyRemote=true,
                      )
                    let connection = makeConnection(
                      ~handshakeId=connectionId,
                      ~session,
                      ~port,
                      ~onMessage,
                      ~onMessageError,
                    )
                    switch state.contents {
                    | Idle => {
                        state := Open(connection)
                        switch state.contents {
                        | Open(current) if current.session === session =>
                          try {
                            installConnection(connection, onMessage, onMessageError)
                            postPortMessage(
                              port,
                              ~kind="ready",
                              ~channel=config.channel,
                              ~connectionId,
                            )
                            connection.session.opened()
                          } catch {
                          | error =>
                            disconnectSession(session, exceptionMessage(error), ~notifyRemote=false)
                          }
                        | Idle | Open(_) | Closed => connection.cleanup()
                        }
                      }
                    | Open(_) | Closed => {
                        connection.cleanup()
                        session.disconnected("Window connection setup was abandoned")
                      }
                    }
                  }
                | Open(_) => closePortSafely(port)
                }
              }
            | None => ()
            }
          | None => ()
          }
        }
      }

      let onPageHide = event => {
        if !pageTransitionPersisted(event) {
          let currentSession = switch state.contents {
          | Open(connection) => Some(connection.session)
          | Idle | Closed => None
          }
          currentSession->Option.forEach(session =>
            disconnectSession(session, "Child window unloading", ~notifyRemote=true)
          )
        }
      }

      BrowserWindow.addEventListener(BrowserWindow.current, "message", onBootstrapMessage)
      try {
        BrowserWindow.addEventListener(BrowserWindow.current, "pagehide", onPageHide)
      } catch {
      | error => {
          BrowserWindow.removeEventListener(BrowserWindow.current, "message", onBootstrapMessage)
          JsError.throwWithMessage(exceptionMessage(error))
        }
      }

      let tornDown = ref(false)
      () => {
        if !tornDown.contents {
          tornDown := true
          let current = switch state.contents {
          | Open(connection) => Some(connection)
          | Idle | Closed => None
          }
          state := Closed
          try {
            BrowserWindow.removeEventListener(BrowserWindow.current, "message", onBootstrapMessage)
          } catch {
          | _ => ()
          }
          try {
            BrowserWindow.removeEventListener(BrowserWindow.current, "pagehide", onPageHide)
          } catch {
          | _ => ()
          }
          current->Option.forEach(connection => {
            closeConnection(
              connection,
              ~channel=config.channel,
              ~reason="Window transport closed",
              ~notifyRemote=true,
            )
          })
        }
      }
    }

    Runtime.makeTransport(~postMessage, ~start, ~maxChunkBytes=config.maxChunkBytes)
  }
}
