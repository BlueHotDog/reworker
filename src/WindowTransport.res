/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

type browserWindow
type messagePort
type messageChannel
type messageEvent

@new external makeMessageChannel: unit => messageChannel = "MessageChannel"
@get external firstPort: messageChannel => messagePort = "port1"
@get external secondPort: messageChannel => messagePort = "port2"
@send external startPort: messagePort => unit = "start"
@send external closePort: messagePort => unit = "close"
@send external postPortMessage: (messagePort, 'a) => unit = "postMessage"
@send
external postWindowMessage: (browserWindow, 'a, string, array<messagePort>) => unit = "postMessage"
@send
external addWindowEventListener: (browserWindow, string, 'event => unit) => unit =
  "addEventListener"
@send
external removeWindowEventListener: (browserWindow, string, 'event => unit) => unit =
  "removeEventListener"
@send
external addPortEventListener: (messagePort, string, 'event => unit) => unit = "addEventListener"
@get external eventData: messageEvent => Obj.t = "data"
@get external eventOrigin: messageEvent => string = "origin"
@get external eventSource: messageEvent => browserWindow = "source"
@get external eventPorts: messageEvent => array<messagePort> = "ports"
@val external currentWindow: browserWindow = "window"

let marker = "@bluehotdog/reworker/window/v1"

type bootstrapMessage = {
  marker: string,
  kind: string,
  connectionId: Id.t,
}

type portMessage = {
  marker: string,
  kind: string,
  connectionId: Id.t,
  payload: option<Obj.t>,
  reason: option<string>,
}

type messageListener = (Obj.t, unit) => unit

type connection = {
  port: messagePort,
  id: Id.t,
  mutable ready: bool,
}

type endpoint = {
  mutable connection: option<connection>,
  messageListeners: ref<array<messageListener>>,
  closeListeners: ref<array<string => unit>>,
}

let makeEndpoint = () => {
  connection: None,
  messageListeners: ref([]),
  closeListeners: ref([]),
}

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

let makePortMessage = (~kind, ~connectionId, ~payload=None, ~reason=None) => {
  marker,
  kind,
  connectionId,
  payload,
  reason,
}

let readPortMessage = value => {
  try {
    let message: portMessage = Obj.magic(value)
    message.marker === marker ? Some(message) : None
  } catch {
  | _ => None
  }
}

let notifyClosed = (endpoint, reason) => {
  endpoint.closeListeners.contents->Array.forEach(listener => listener(reason))
}

let disconnect = (endpoint, reason, ~notifyRemote) => {
  switch endpoint.connection {
  | None => ()
  | Some(connection) => {
      endpoint.connection = None
      if notifyRemote {
        try {
          postPortMessage(
            connection.port,
            makePortMessage(~kind="close", ~connectionId=connection.id, ~reason=Some(reason)),
          )
        } catch {
        | _ => ()
        }
      }
      closePort(connection.port)
      notifyClosed(endpoint, reason)
    }
  }
}

let isCurrentConnection = (endpoint, connection) => {
  switch endpoint.connection {
  | Some(current) => current === connection
  | None => false
  }
}

let activate = (endpoint, port, id, ~ready, ~onReady) => {
  let connection = {port, id, ready}
  endpoint.connection = Some(connection)

  let onMessage = event => {
    if isCurrentConnection(endpoint, connection) {
      switch readPortMessage(eventData(event)) {
      | Some(message) if message.connectionId === id =>
        switch message.kind {
        | "ready" => onReady()
        | "data" if connection.ready =>
          switch message.payload {
          | Some(payload) =>
            endpoint.messageListeners.contents->Array.forEach(listener => listener(payload, ()))
          | None => disconnect(endpoint, "Received an invalid port message", ~notifyRemote=true)
          }
        | "close" =>
          disconnect(
            endpoint,
            message.reason->Option.getOr("Remote endpoint closed"),
            ~notifyRemote=false,
          )
        | _ => ()
        }
      | Some(_) => ()
      | None => disconnect(endpoint, "Received an invalid port message", ~notifyRemote=true)
      }
    }
  }
  let onMessageError = _event => {
    if isCurrentConnection(endpoint, connection) {
      disconnect(endpoint, "Message port could not deserialize a value", ~notifyRemote=true)
    }
  }

  addPortEventListener(port, "message", onMessage)
  addPortEventListener(port, "messageerror", onMessageError)
  startPort(port)
}

let markReady = endpoint => {
  switch endpoint.connection {
  | Some(connection) => connection.ready = true
  | None => ()
  }
}

let post = (endpoint, message) => {
  switch endpoint.connection {
  | Some(connection) if connection.ready =>
    try {
      postPortMessage(
        connection.port,
        makePortMessage(
          ~kind="data",
          ~connectionId=connection.id,
          ~payload=Some(Obj.magic(message)),
        ),
      )
      Ok()
    } catch {
    | error =>
      Error(
        error
        ->JsExn.fromException
        ->Option.flatMap(JsExn.message)
        ->Option.getOr("Message could not be cloned"),
      )
    }
  | Some(_) => Error("Window transport is not ready")
  | None => Error("Window transport is closed")
  }
}

let isOpen = endpoint => {
  switch endpoint.connection {
  | Some(connection) => connection.ready
  | None => false
  }
}

module Parent = {
  module Make = (
    Config: {
      type targetWindow
      type loadEvent
      let targetOrigin: string
      let targetWindow: unit => targetWindow
      let addLoadListener: (loadEvent => unit) => unit
      let removeLoadListener: (loadEvent => unit) => unit
      let requestTimeoutMs: int
    },
  ) => {
    type sender = unit

    type connectionAttempt = {
      id: Id.t,
      resolve: unit => unit,
      reject: JsError.t => unit,
      timeoutId: timeoutId,
    }

    let requestTimeoutMs = Config.requestTimeoutMs
    let endpoint = makeEndpoint()
    let attempt: ref<option<connectionAttempt>> = ref(None)
    let listeningForLoads = ref(false)
    let reconnect = ref(() => ())

    let rejectAttempt = reason => {
      switch attempt.contents {
      | Some(current) => {
          clearTimeout(current.timeoutId)
          attempt := None
          current.reject(JsError.make(reason))
        }
      | None => ()
      }
    }

    endpoint.closeListeners := endpoint.closeListeners.contents->Array.concat([rejectAttempt])

    let closeConnection = reason => {
      rejectAttempt(reason)
      disconnect(endpoint, reason, ~notifyRemote=true)
    }

    let loadHandler = _event => reconnect.contents()

    let rejectPromise = message => {
      Promise.make((_resolve, reject) => reject(JsError.make(message)))
    }

    let connect = () => {
      if Config.targetOrigin === "" || Config.targetOrigin === "*" {
        rejectPromise("targetOrigin must be an explicit origin")
      } else {
        if !listeningForLoads.contents {
          listeningForLoads := true
          Config.addLoadListener(loadHandler)
        }
        closeConnection("Iframe navigation replaced the connection")

        let targetWindow = Config.targetWindow()
        let id = Id.make()
        let channel = makeMessageChannel()
        let port = firstPort(channel)
        Promise.make((resolve, reject) => {
          let timeoutId = setTimeout(() => {
            rejectAttempt("Window transport readiness timed out")
            disconnect(endpoint, "Window transport readiness timed out", ~notifyRemote=true)
          }, Config.requestTimeoutMs)
          attempt := Some({id, resolve, reject, timeoutId})

          activate(endpoint, port, id, ~ready=false, ~onReady=() => {
            switch attempt.contents {
            | Some(current) if current.id === id => {
                clearTimeout(current.timeoutId)
                attempt := None
                markReady(endpoint)
                current.resolve()
              }
            | Some(_) | None => ()
            }
          })

          try {
            let bootstrap = {marker, kind: "connect", connectionId: id}
            postWindowMessage(
              Obj.magic(targetWindow),
              bootstrap,
              Config.targetOrigin,
              [secondPort(channel)],
            )
          } catch {
          | error => {
              let reason =
                error
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("Failed to transfer the message port")
              rejectAttempt(reason)
              disconnect(endpoint, reason, ~notifyRemote=false)
            }
          }
        })
      }
    }

    reconnect :=
      (
        () => {
          closeConnection("Iframe reloaded")
          connect()->Promise.catch(_ => Promise.resolve())->ignore
        }
      )

    let postMessage = message => post(endpoint, message)

    module OnMessage = {
      let addListener = listener => {
        endpoint.messageListeners :=
          endpoint.messageListeners.contents->Array.concat([Obj.magic(listener)])
      }
      let removeListener = listener => {
        removeFirst(endpoint.messageListeners, Obj.magic(listener))
      }
    }

    module OnClose = {
      let addListener = listener => {
        endpoint.closeListeners := endpoint.closeListeners.contents->Array.concat([listener])
      }
    }

    let isOpen = () => isOpen(endpoint)

    let close = () => {
      if listeningForLoads.contents {
        listeningForLoads := false
        Config.removeLoadListener(loadHandler)
      }
      closeConnection("Window transport closed")
    }
  }
}

module Child = {
  module Make = (
    Config: {
      type parentWindow
      let parentWindow: parentWindow
      let parentOrigin: string
      let requestTimeoutMs: int
    },
  ) => {
    type sender = unit

    let requestTimeoutMs = Config.requestTimeoutMs
    let endpoint = makeEndpoint()
    let listening = ref(false)

    let onBootstrapMessage = event => {
      let sourceMatches = eventSource(event) === Obj.magic(Config.parentWindow)

      if eventOrigin(event) === Config.parentOrigin && sourceMatches {
        try {
          let bootstrap: bootstrapMessage = Obj.magic(eventData(event))
          if bootstrap.marker === marker && bootstrap.kind === "connect" {
            switch eventPorts(event)->Array.get(0) {
            | Some(port) => {
                disconnect(endpoint, "Parent replaced the connection", ~notifyRemote=false)
                activate(endpoint, port, bootstrap.connectionId, ~ready=true, ~onReady=() => ())
                try {
                  postPortMessage(
                    port,
                    makePortMessage(~kind="ready", ~connectionId=bootstrap.connectionId),
                  )
                } catch {
                | _ =>
                  disconnect(
                    endpoint,
                    "Failed to confirm window transport readiness",
                    ~notifyRemote=true,
                  )
                }
              }
            | None => ()
            }
          }
        } catch {
        | _ => ()
        }
      }
    }

    let listen = () => {
      if Config.parentOrigin === "" || Config.parentOrigin === "*" {
        Error("parentOrigin must be an explicit origin")
      } else if listening.contents {
        Ok()
      } else {
        listening := true
        addWindowEventListener(currentWindow, "message", onBootstrapMessage)
        Ok()
      }
    }

    let postMessage = message => post(endpoint, message)

    module OnMessage = {
      let addListener = listener => {
        endpoint.messageListeners :=
          endpoint.messageListeners.contents->Array.concat([Obj.magic(listener)])
      }
      let removeListener = listener => {
        removeFirst(endpoint.messageListeners, Obj.magic(listener))
      }
    }

    module OnClose = {
      let addListener = listener => {
        endpoint.closeListeners := endpoint.closeListeners.contents->Array.concat([listener])
      }
    }

    let isOpen = () => isOpen(endpoint)

    let close = () => {
      if listening.contents {
        listening := false
        removeWindowEventListener(currentWindow, "message", onBootstrapMessage)
      }
      disconnect(endpoint, "Window transport closed", ~notifyRemote=true)
    }
  }
}
