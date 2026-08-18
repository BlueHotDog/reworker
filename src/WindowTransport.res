/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

let marker = "@bluehotdog/reworker/window/v2"

@scope("Number") @val external isSafeInteger: Obj.t => bool = "isSafeInteger"
@scope("Object") @val external hasOwn: (Obj.t, string) => bool = "hasOwn"
@val external errorToString: 'a => string = "String"
@get external pageTransitionPersisted: Obj.t => bool = "persisted"

type bootstrapMessage = {marker: string, kind: string, channel: string}

type portMessage = {
  kind: string,
  payload?: Obj.t,
  reason?: string,
}

type incoming = Ready | Data(Obj.t) | RemoteClose(string) | Invalid

type connection = {
  session: Runtime.session<unit>,
  port: MessagePort.t,
  ready: ref<bool>,
  timeoutId: option<timeoutId>,
  cleanup: unit => unit,
}

type state = Running(option<connection>) | Closed

let exceptionMessage = error =>
  error->JsExn.fromException->Option.flatMap(JsExn.message)->Option.getOr(errorToString(error))

let validateEndpointConfig = (~origin, ~originName, ~channel) => {
  if origin === "" || origin === "*" {
    JsError.throwWithMessage(`${originName} must be an explicit origin`)
  }
  if channel === "" {
    JsError.throwWithMessage("channel must not be empty")
  }
}

let safely = callback => {
  try {
    callback()
  } catch {
  | _ => ()
  }
}

let closePort = port => safely(() => MessagePort.close(port))

let postPortMessage = (port, ~kind, ~payload=?, ~reason=?) => {
  let message: portMessage = {kind, ?payload, ?reason}
  MessagePort.postMessage(port, message)
}

let readPortMessage = value => {
  try {
    let message: portMessage = Obj.magic(value)
    switch message.kind {
    | "ready" => Ready
    | "data" if hasOwn(Obj.magic(message), "payload") =>
      Data(message.payload->Option.getOr(Obj.magic(undefined)))
    | "close"
      if hasOwn(Obj.magic(message), "reason") &&
      Type.typeof(Obj.magic(message.reason)) === #string =>
      RemoteClose(message.reason->Option.getOr("Remote endpoint closed"))
    | _ => Invalid
    }
  } catch {
  | _ => Invalid
  }
}

let isBootstrapMessage = (value, ~channel) => {
  try {
    let message: bootstrapMessage = Obj.magic(value)
    message.marker === marker && message.kind === "connect" && message.channel === channel
  } catch {
  | _ => false
  }
}

let makeConnection = (~session, ~port, ~onMessage, ~onMessageError, ~timeoutId=None) => {
  let cleanup = () => {
    timeoutId->Option.forEach(clearTimeout)
    safely(() => MessagePort.removeEventListener(port, "message", onMessage))
    safely(() => MessagePort.removeEventListener(port, "messageerror", onMessageError))
    closePort(port)
  }
  {session, port, ready: ref(false), timeoutId, cleanup}
}

let installConnection = (connection, onMessage, onMessageError) => {
  MessagePort.addEventListener(connection.port, "message", onMessage)
  MessagePort.addEventListener(connection.port, "messageerror", onMessageError)
  MessagePort.start(connection.port)
}

let currentConnection = (state, session) => {
  switch state.contents {
  | Running(Some(connection)) if connection.session === session => Some(connection)
  | Running(None | Some(_)) | Closed => None
  }
}

let closeConnection = (connection, ~reason, ~notifyRemote) => {
  if notifyRemote {
    safely(() => postPortMessage(connection.port, ~kind="close", ~reason))
  }
  connection.cleanup()
}

let disconnectSession = (state, session, reason, ~notifyRemote) => {
  currentConnection(state, session)->Option.forEach(connection => {
    state := Running(None)
    closeConnection(connection, ~reason, ~notifyRemote)
    session.disconnected(reason)
  })
}

let disconnectCurrent = (state, reason, ~notifyRemote) => {
  switch state.contents {
  | Running(Some(connection)) => disconnectSession(state, connection.session, reason, ~notifyRemote)
  | Running(None) | Closed => ()
  }
}

let receivePortMessage = (state, session, value, ~onReady) => {
  currentConnection(state, session)->Option.forEach(connection => {
    switch readPortMessage(value) {
    | Ready if onReady(connection) => ()
    | Data(payload) if connection.ready.contents => session.message(payload, ())
    | RemoteClose(reason) => disconnectSession(state, session, reason, ~notifyRemote=false)
    | Ready | Data(_) | Invalid =>
      disconnectSession(state, session, "Received an invalid port message", ~notifyRemote=true)
    }
  })
}

let receivePortError = (state, session) =>
  disconnectSession(
    state,
    session,
    "Message port could not deserialize a value",
    ~notifyRemote=true,
  )

let closeTransport = (state, cleanup) => {
  switch state.contents {
  | Closed => ()
  | Running(connection) => {
      state := Closed
      connection->Option.forEach(connection =>
        closeConnection(connection, ~reason="Window transport closed", ~notifyRemote=true)
      )
      safely(cleanup)
    }
  }
}

let postData = (state, payload) => {
  switch state.contents {
  | Running(Some(connection)) if connection.ready.contents =>
    try {
      postPortMessage(connection.port, ~kind="data", ~payload)
      Ok()
    } catch {
    | error => Error(exceptionMessage(error))
    }
  | Running(None | Some(_)) => Error("Window transport is not connected")
  | Closed => Error("Window transport is closed")
  }
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

  let make = config => {
    validateEndpointConfig(
      ~origin=config.targetOrigin,
      ~originName="targetOrigin",
      ~channel=config.channel,
    )
    if !isSafeInteger(Obj.magic(config.connectionTimeoutMs)) || config.connectionTimeoutMs <= 0 {
      JsError.throwWithMessage("connectionTimeoutMs is invalid")
    }

    let state = ref(Running(None))
    let cleanup = ref(() => ())
    let postMessage = payload => postData(state, payload)
    let close = () => closeTransport(state, cleanup.contents)

    let start = (~prepareSession) => {
      let startConnection = () => {
        switch state.contents {
        | Closed | Running(Some(_)) => ()
        | Running(None) => {
            let channel = MessageChannel.make()
            let port = MessageChannel.port1(channel)
            let remotePort = MessageChannel.port2(channel)
            let session = prepareSession()
            let onMessage = event =>
              receivePortMessage(state, session, MessageEvent.data(event), ~onReady=connection => {
                if connection.ready.contents {
                  false
                } else {
                  connection.timeoutId->Option.forEach(clearTimeout)
                  connection.ready := true
                  session.opened()
                  true
                }
              })
            let onMessageError = _event => receivePortError(state, session)
            let timeoutId = setTimeout(
              () =>
                disconnectSession(
                  state,
                  session,
                  "Window transport readiness timed out",
                  ~notifyRemote=true,
                ),
              config.connectionTimeoutMs,
            )
            let connection = makeConnection(
              ~session,
              ~port,
              ~onMessage,
              ~onMessageError,
              ~timeoutId=Some(timeoutId),
            )
            state := Running(Some(connection))
            try {
              installConnection(connection, onMessage, onMessageError)
              let bootstrap: bootstrapMessage = {marker, kind: "connect", channel: config.channel}
              BrowserWindow.postMessage(
                Obj.magic(config.targetWindow),
                bootstrap,
                config.targetOrigin,
                [remotePort],
              )
              session.connecting()
            } catch {
            | error => {
                closePort(remotePort)
                disconnectSession(state, session, exceptionMessage(error), ~notifyRemote=false)
                JsError.throw(Obj.magic(error))
              }
            }
          }
        }
      }

      let onLoad = () => {
        disconnectCurrent(state, "Iframe reloaded", ~notifyRemote=true)
        try {
          startConnection()
        } catch {
        | _ => ()
        }
      }

      let remove = config.subscribeLoad(onLoad)
      switch state.contents {
      | Closed => remove()
      | Running(_) => {
          cleanup := remove
          startConnection()
        }
      }
    }

    Runtime.makeDynamicTransport(~postMessage, ~start, ~close, ~maxChunkBytes=config.maxChunkBytes)
  }
}

module Child = {
  type config<'parentWindow> = {
    parentWindow: 'parentWindow,
    parentOrigin: string,
    channel: string,
    maxChunkBytes: int,
  }

  let make = config => {
    validateEndpointConfig(
      ~origin=config.parentOrigin,
      ~originName="parentOrigin",
      ~channel=config.channel,
    )

    let state = ref(Running(None))
    let cleanup = ref(() => ())
    let postMessage = payload => postData(state, payload)
    let close = () => closeTransport(state, cleanup.contents)

    let start = (~prepareSession) => {
      let onBootstrapMessage = event => {
        if (
          MessageEvent.origin(event) === config.parentOrigin &&
            MessageEvent.source(event) === Obj.magic(config.parentWindow)
        ) {
          switch (
            isBootstrapMessage(MessageEvent.data(event), ~channel=config.channel),
            MessageEvent.ports(event)->Array.get(0),
          ) {
          | (true, Some(port)) => {
              disconnectCurrent(state, "Parent replaced the connection", ~notifyRemote=false)
              switch state.contents {
              | Closed | Running(Some(_)) => closePort(port)
              | Running(None) => {
                  let session = prepareSession()
                  let onMessage = portEvent =>
                    receivePortMessage(state, session, MessageEvent.data(portEvent), ~onReady=_ =>
                      false
                    )
                  let onMessageError = _event => receivePortError(state, session)
                  let connection = makeConnection(~session, ~port, ~onMessage, ~onMessageError)
                  state := Running(Some(connection))
                  try {
                    installConnection(connection, onMessage, onMessageError)
                    postPortMessage(port, ~kind="ready")
                    connection.ready := true
                    session.connecting()
                    session.opened()
                  } catch {
                  | error => {
                      session.connecting()
                      disconnectSession(
                        state,
                        session,
                        exceptionMessage(error),
                        ~notifyRemote=false,
                      )
                    }
                  }
                }
              }
            }
          | _ => ()
          }
        }
      }
      let onPageHide = event => {
        if !pageTransitionPersisted(event) {
          disconnectCurrent(state, "Child window unloading", ~notifyRemote=true)
        }
      }

      BrowserWindow.addEventListener(BrowserWindow.current, "message", onBootstrapMessage)
      try {
        BrowserWindow.addEventListener(BrowserWindow.current, "pagehide", onPageHide)
        cleanup :=
          (
            () => {
              safely(() =>
                BrowserWindow.removeEventListener(
                  BrowserWindow.current,
                  "message",
                  onBootstrapMessage,
                )
              )
              safely(() =>
                BrowserWindow.removeEventListener(BrowserWindow.current, "pagehide", onPageHide)
              )
            }
          )
      } catch {
      | error => {
          safely(() =>
            BrowserWindow.removeEventListener(BrowserWindow.current, "message", onBootstrapMessage)
          )
          JsError.throw(Obj.magic(error))
        }
      }
    }

    Runtime.makeDynamicTransport(~postMessage, ~start, ~close, ~maxChunkBytes=config.maxChunkBytes)
  }
}
