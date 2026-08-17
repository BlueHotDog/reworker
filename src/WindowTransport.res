/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

let marker = "@bluehotdog/reworker/window/v1"

@get external pageTransitionPersisted: Obj.t => bool = "persisted"

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

type messageListener = (Obj.t, int) => unit

type connection = {
  port: MessagePort.t,
  id: Id.t,
  generation: int,
  mutable ready: bool,
  mutable onMessage: option<MessageEvent.t => unit>,
  mutable onMessageError: option<MessageEvent.t => unit>,
}

type endpoint = {
  mutable connection: option<connection>,
  mutable generation: int,
  messageListeners: ref<array<messageListener>>,
  openListeners: ref<array<unit => unit>>,
  closeListeners: ref<array<string => unit>>,
}

let makeEndpoint = () => {
  connection: None,
  generation: 0,
  messageListeners: ref([]),
  openListeners: ref([]),
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

let notifyOpened = endpoint => {
  endpoint.openListeners.contents->Array.forEach(listener => listener())
}

let disconnect = (endpoint, reason, ~notifyRemote) => {
  switch endpoint.connection {
  | None => ()
  | Some(connection) => {
      endpoint.connection = None
      if notifyRemote {
        try {
          MessagePort.postMessage(
            connection.port,
            makePortMessage(~kind="close", ~connectionId=connection.id, ~reason=Some(reason)),
          )
        } catch {
        | _ => ()
        }
      }
      switch connection.onMessage {
      | Some(listener) => MessagePort.removeEventListener(connection.port, "message", listener)
      | None => ()
      }
      switch connection.onMessageError {
      | Some(listener) => MessagePort.removeEventListener(connection.port, "messageerror", listener)
      | None => ()
      }
      MessagePort.close(connection.port)
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

let activate = (endpoint: endpoint, port, id, ~ready, ~onReady) => {
  endpoint.generation = endpoint.generation + 1
  let connection = {
    port,
    id,
    generation: endpoint.generation,
    ready,
    onMessage: None,
    onMessageError: None,
  }
  endpoint.connection = Some(connection)

  let onMessage = event => {
    if isCurrentConnection(endpoint, connection) {
      switch readPortMessage(MessageEvent.data(event)) {
      | Some(message) if message.connectionId === id =>
        switch message.kind {
        | "ready" => onReady()
        | "data" if connection.ready =>
          switch message.payload {
          | Some(payload) =>
            endpoint.messageListeners.contents->Array.forEach(listener =>
              listener(payload, connection.generation)
            )
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

  connection.onMessage = Some(onMessage)
  connection.onMessageError = Some(onMessageError)
  MessagePort.addEventListener(port, "message", onMessage)
  MessagePort.addEventListener(port, "messageerror", onMessageError)
  MessagePort.start(port)
  if ready {
    notifyOpened(endpoint)
  }
}

let markReady = endpoint => {
  switch endpoint.connection {
  | Some(connection) if !connection.ready => {
      connection.ready = true
      notifyOpened(endpoint)
    }
  | Some(_) => ()
  | None => ()
  }
}

let post = (endpoint, message) => {
  switch endpoint.connection {
  | Some(connection) if connection.ready =>
    try {
      MessagePort.postMessage(
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

let makeTransport:
  type extension. (
    ~endpoint: endpoint,
    ~requestTimeoutMs: int,
    ~maxMessageBytes: int,
    ~maxPendingRequests: int,
    ~maxChunkBytes: int,
    ~extension: extension,
    ~close: unit => unit,
  ) => Runtime.transport<int, extension> =
  (
    ~endpoint,
    ~requestTimeoutMs,
    ~maxMessageBytes,
    ~maxPendingRequests,
    ~maxChunkBytes,
    ~extension,
    ~close,
  ) => {
    requestTimeoutMs,
    maxMessageBytes,
    maxPendingRequests,
    maxChunkBytes,
    postMessage: message => post(endpoint, message),
    addMessageListener: listener => {
      endpoint.messageListeners := endpoint.messageListeners.contents->Array.concat([listener])
    },
    removeMessageListener: listener => removeFirst(endpoint.messageListeners, listener),
    addOpenListener: listener => {
      endpoint.openListeners := endpoint.openListeners.contents->Array.concat([listener])
    },
    removeOpenListener: listener => removeFirst(endpoint.openListeners, listener),
    addCloseListener: listener => {
      endpoint.closeListeners := endpoint.closeListeners.contents->Array.concat([listener])
    },
    removeCloseListener: listener => removeFirst(endpoint.closeListeners, listener),
    isOpen: () => isOpen(endpoint),
    isCurrentSender: generation => {
      switch endpoint.connection {
      | Some(connection) => connection.generation === generation
      | None => false
      }
    },
    senderKey: generation => generation->Int.toString,
    close,
    extension,
  }

module Parent = {
  type config<'targetWindow, 'loadEvent> = {
    targetWindow: 'targetWindow,
    targetOrigin: string,
    isTargetLoaded: unit => bool,
    addLoadListener: ('loadEvent => unit) => unit,
    removeLoadListener: ('loadEvent => unit) => unit,
    requestTimeoutMs: int,
    maxMessageBytes: int,
    maxPendingRequests: int,
    maxChunkBytes: int,
  }

  type connectionAttempt = {
    id: Id.t,
    resolve: unit => unit,
    reject: JsError.t => unit,
    timeoutId: timeoutId,
  }

  type extension<'targetWindow, 'loadEvent> = {
    config: config<'targetWindow, 'loadEvent>,
    endpoint: endpoint,
    attempt: ref<option<connectionAttempt>>,
    listeningForLoads: ref<bool>,
    ignoreNextLoad: ref<bool>,
    loadHandler: 'loadEvent => unit,
    mutable closed: bool,
  }

  type t<'targetWindow, 'loadEvent> = Runtime.transport<int, extension<'targetWindow, 'loadEvent>>

  let rejectAttempt = (state, reason) => {
    switch state.attempt.contents {
    | Some(current) => {
        clearTimeout(current.timeoutId)
        state.attempt := None
        current.reject(JsError.make(reason))
      }
    | None => ()
    }
  }

  let closeConnection = (state, reason) => {
    rejectAttempt(state, reason)
    disconnect(state.endpoint, reason, ~notifyRemote=true)
  }

  let rejectPromise = message => Promise.make((_resolve, reject) => reject(JsError.make(message)))

  let connect:
    type targetWindow loadEvent. t<targetWindow, loadEvent> => promise<unit> =
    transport => {
      let state = transport.extension
      if state.closed {
        rejectPromise("Window transport is closed")
      } else if state.config.targetOrigin === "" || state.config.targetOrigin === "*" {
        rejectPromise("targetOrigin must be an explicit origin")
      } else {
        if !state.listeningForLoads.contents {
          state.ignoreNextLoad := !state.config.isTargetLoaded()
          state.listeningForLoads := true
          state.config.addLoadListener(state.loadHandler)
        }
        closeConnection(state, "Iframe navigation replaced the connection")

        let id = Id.make()
        let channel = MessageChannel.make()
        let port = MessageChannel.port1(channel)
        Promise.make((resolve, reject) => {
          let timeoutId = setTimeout(() => {
            rejectAttempt(state, "Window transport readiness timed out")
            disconnect(state.endpoint, "Window transport readiness timed out", ~notifyRemote=true)
          }, state.config.requestTimeoutMs)
          state.attempt := Some({id, resolve, reject, timeoutId})

          activate(state.endpoint, port, id, ~ready=false, ~onReady=() => {
            switch state.attempt.contents {
            | Some(current) if current.id === id => {
                clearTimeout(current.timeoutId)
                state.attempt := None
                markReady(state.endpoint)
                current.resolve()
              }
            | Some(_) | None => ()
            }
          })

          try {
            let bootstrap = {marker, kind: "connect", connectionId: id}
            BrowserWindow.postMessage(
              Obj.magic(state.config.targetWindow),
              bootstrap,
              state.config.targetOrigin,
              [MessageChannel.port2(channel)],
            )
          } catch {
          | error => {
              let reason =
                error
                ->JsExn.fromException
                ->Option.flatMap(JsExn.message)
                ->Option.getOr("Failed to transfer the message port")
              rejectAttempt(state, reason)
              disconnect(state.endpoint, reason, ~notifyRemote=false)
            }
          }
        })
      }
    }

  let make = config => {
    let endpoint = makeEndpoint()
    let reconnect = ref(() => ())
    let ignoreNextLoad = ref(false)
    let loadHandler = _event => {
      if ignoreNextLoad.contents {
        ignoreNextLoad := false
        switch endpoint.connection {
        | Some(connection) if connection.ready => ()
        | Some(_) | None => reconnect.contents()
        }
      } else {
        reconnect.contents()
      }
    }
    let state = {
      config,
      endpoint,
      attempt: ref(None),
      listeningForLoads: ref(false),
      ignoreNextLoad,
      loadHandler,
      closed: false,
    }
    endpoint.closeListeners :=
      endpoint.closeListeners.contents->Array.concat([reason => rejectAttempt(state, reason)])

    let transport = makeTransport(
      ~endpoint,
      ~requestTimeoutMs=config.requestTimeoutMs,
      ~maxMessageBytes=config.maxMessageBytes,
      ~maxPendingRequests=config.maxPendingRequests,
      ~maxChunkBytes=config.maxChunkBytes,
      ~extension=state,
      ~close=() => {
        if !state.closed {
          state.closed = true
          if state.listeningForLoads.contents {
            state.listeningForLoads := false
            state.config.removeLoadListener(state.loadHandler)
          }
          closeConnection(state, "Window transport closed")
        }
      },
    )

    reconnect :=
      (
        () => {
          if !state.closed {
            closeConnection(state, "Iframe reloaded")
            connect(transport)->Promise.catch(_ => Promise.resolve())->ignore
          }
        }
      )

    transport
  }
}

module Child = {
  type config<'parentWindow> = {
    parentWindow: 'parentWindow,
    parentOrigin: string,
    requestTimeoutMs: int,
    maxMessageBytes: int,
    maxPendingRequests: int,
    maxChunkBytes: int,
  }

  type extension<'parentWindow> = {
    config: config<'parentWindow>,
    listening: ref<bool>,
    mutable bootstrapHandler: option<MessageEvent.t => unit>,
    mutable pageHideHandler: option<Obj.t => unit>,
    mutable closed: bool,
  }

  type t<'parentWindow> = Runtime.transport<int, extension<'parentWindow>>

  let listen:
    type parentWindow. t<parentWindow> => result<unit, string> =
    transport => {
      let state = transport.extension
      if state.closed {
        Error("Window transport is closed")
      } else if state.config.parentOrigin === "" || state.config.parentOrigin === "*" {
        Error("parentOrigin must be an explicit origin")
      } else if state.listening.contents {
        Ok()
      } else {
        switch state.bootstrapHandler {
        | Some(handler) => {
            state.listening := true
            BrowserWindow.addEventListener(BrowserWindow.current, "message", handler)
            switch state.pageHideHandler {
            | Some(handler) =>
              BrowserWindow.addEventListener(BrowserWindow.current, "pagehide", handler)
            | None => ()
            }
            Ok()
          }
        | None => Error("Window transport is closed")
        }
      }
    }

  let make = config => {
    let endpoint = makeEndpoint()
    let state = {
      config,
      listening: ref(false),
      bootstrapHandler: None,
      pageHideHandler: None,
      closed: false,
    }
    let onPageHide = event => {
      if !pageTransitionPersisted(event) {
        disconnect(endpoint, "Child window unloading", ~notifyRemote=true)
      }
    }
    let onBootstrapMessage = event => {
      let sourceMatches = MessageEvent.source(event) === Obj.magic(state.config.parentWindow)

      if MessageEvent.origin(event) === state.config.parentOrigin && sourceMatches {
        try {
          let bootstrap: bootstrapMessage = Obj.magic(MessageEvent.data(event))
          if bootstrap.marker === marker && bootstrap.kind === "connect" {
            switch MessageEvent.ports(event)->Array.get(0) {
            | Some(port) => {
                disconnect(endpoint, "Parent replaced the connection", ~notifyRemote=false)
                activate(endpoint, port, bootstrap.connectionId, ~ready=false, ~onReady=() => ())
                try {
                  MessagePort.postMessage(
                    port,
                    makePortMessage(~kind="ready", ~connectionId=bootstrap.connectionId),
                  )
                  markReady(endpoint)
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
    state.bootstrapHandler = Some(onBootstrapMessage)
    state.pageHideHandler = Some(onPageHide)

    makeTransport(
      ~endpoint,
      ~requestTimeoutMs=config.requestTimeoutMs,
      ~maxMessageBytes=config.maxMessageBytes,
      ~maxPendingRequests=config.maxPendingRequests,
      ~maxChunkBytes=config.maxChunkBytes,
      ~extension=state,
      ~close=() => {
        if !state.closed {
          state.closed = true
          if state.listening.contents {
            state.listening := false
            BrowserWindow.removeEventListener(BrowserWindow.current, "message", onBootstrapMessage)
            BrowserWindow.removeEventListener(BrowserWindow.current, "pagehide", onPageHide)
          }
          state.bootstrapHandler = None
          state.pageHideHandler = None
          disconnect(endpoint, "Window transport closed", ~notifyRemote=true)
        }
      },
    )
  }
}
