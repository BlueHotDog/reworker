/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Channel functor for background connections (chrome.runtime.connect)
module MakeToBackground = (
  Bindings: {
    // Subset of RuntimeBindings needed for background connections
    type port
    let connect: (~extensionId: string=?, ~name: string=?) => option<port>
    module Port: {
      let postMessage: (port, 'a) => result<unit, string>
      let disconnect: port => unit
      let name: port => option<string>
      module OnMessage: {
        let addListener: (port, 'a => unit) => result<unit, string>
        let removeListener: (port, 'a => unit) => result<unit, string>
      }
      module OnDisconnect: {
        let addListener: (port, port => unit) => result<unit, string>
      }
    }
  },
  MessageSpec: {
    type message<_>
  },
) => {
  // Generate unique channel ID and use it as the port name
  let channelId = Id.make()
  let channelNameString = Id.toString(channelId)

  // Channel state type
  type t = ChannelTypes.channelState<Bindings.port>

  // Channel operations
  let connect = (~extensionId=?) => {
    switch Bindings.connect(~extensionId?, ~name=channelNameString) {
    | None => None
    | Some(port) => {
        let channel: ChannelTypes.channelState<Bindings.port> = {
          channelName: ChannelTypes.makeChannelId(channelId),
          port,
          isConnected: ref(true),
        }

        // Automatically track disconnect state
        Bindings.Port.OnDisconnect.addListener(port, _disconnectedPort => {
          (channel: ChannelTypes.channelState<Bindings.port>).isConnected := false
        })->ignore

        Some(channel)
      }
    }
  }

  let post:
    type a. (t, MessageSpec.message<a>) => result<unit, string> =
    (channel, message) => {
      if (channel: ChannelTypes.channelState<Bindings.port>).isConnected.contents {
        Bindings.Port.postMessage((channel: ChannelTypes.channelState<Bindings.port>).port, message)
      } else {
        Error("Channel is disconnected")
      }
    }

  let disconnect = channel => {
    (channel: ChannelTypes.channelState<Bindings.port>).isConnected := false
    Bindings.Port.disconnect((channel: ChannelTypes.channelState<Bindings.port>).port)
  }

  let addHandler:
    type a. (t, MessageSpec.message<a> => unit) => result<unit, string> =
    (channel, handler) => {
      Bindings.Port.OnMessage.addListener(
        (channel: ChannelTypes.channelState<Bindings.port>).port,
        handler,
      )
    }

  let removeHandler:
    type a. (t, MessageSpec.message<a> => unit) => result<unit, string> =
    (channel, handler) => {
      Bindings.Port.OnMessage.removeListener(
        (channel: ChannelTypes.channelState<Bindings.port>).port,
        handler,
      )
    }

  let addDisconnectHandler = (channel, handler) => {
    Bindings.Port.OnDisconnect.addListener(
      (channel: ChannelTypes.channelState<Bindings.port>).port,
      handler,
    )
  }
}

// Channel functor for tab connections (chrome.tabs.connect)
module MakeToTab = (
  Bindings: {
    // Subset of RuntimeBindings needed for tab connections
    type port
    let connectToTab: (~tabId: int, ~frameId: int=?, ~name: string=?) => option<port>
    module Port: {
      let postMessage: (port, 'a) => result<unit, string>
      let disconnect: port => unit
      let name: port => option<string>
      module OnMessage: {
        let addListener: (port, 'a => unit) => result<unit, string>
        let removeListener: (port, 'a => unit) => result<unit, string>
      }
      module OnDisconnect: {
        let addListener: (port, port => unit) => result<unit, string>
      }
    }
  },
  MessageSpec: {
    type message<_>
  },
) => {
  // Generate unique channel ID and use it as the port name
  let channelId = Id.make()
  let channelNameString = Id.toString(channelId)

  // Channel state type
  type t = ChannelTypes.channelState<Bindings.port>

  // Connect requires tabId (different from background connections)
  let connect = (~tabId, ~frameId=?) => {
    switch Bindings.connectToTab(~tabId, ~frameId?, ~name=channelNameString) {
    | None => None
    | Some(port) => {
        let channel: ChannelTypes.channelState<Bindings.port> = {
          channelName: ChannelTypes.makeChannelId(channelId),
          port,
          isConnected: ref(true),
        }

        // Automatically track disconnect state
        Bindings.Port.OnDisconnect.addListener(port, _disconnectedPort => {
          (channel: ChannelTypes.channelState<Bindings.port>).isConnected := false
        })->ignore

        Some(channel)
      }
    }
  }

  // post, disconnect, handlers identical to MakeToBackground
  let post:
    type a. (t, MessageSpec.message<a>) => result<unit, string> =
    (channel, message) => {
      if (channel: ChannelTypes.channelState<Bindings.port>).isConnected.contents {
        Bindings.Port.postMessage((channel: ChannelTypes.channelState<Bindings.port>).port, message)
      } else {
        Error("Channel is disconnected")
      }
    }

  let disconnect = channel => {
    (channel: ChannelTypes.channelState<Bindings.port>).isConnected := false
    Bindings.Port.disconnect((channel: ChannelTypes.channelState<Bindings.port>).port)
  }

  let addHandler:
    type a. (t, MessageSpec.message<a> => unit) => result<unit, string> =
    (channel, handler) => {
      Bindings.Port.OnMessage.addListener(
        (channel: ChannelTypes.channelState<Bindings.port>).port,
        handler,
      )
    }

  let removeHandler:
    type a. (t, MessageSpec.message<a> => unit) => result<unit, string> =
    (channel, handler) => {
      Bindings.Port.OnMessage.removeListener(
        (channel: ChannelTypes.channelState<Bindings.port>).port,
        handler,
      )
    }

  let addDisconnectHandler = (channel, handler) => {
    Bindings.Port.OnDisconnect.addListener(
      (channel: ChannelTypes.channelState<Bindings.port>).port,
      handler,
    )
  }
}
