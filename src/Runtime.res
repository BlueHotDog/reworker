/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Generic Runtime wrapper for message passing with automatic chunking
// Users provide their own messaging bindings (WebWorker, ServiceWorker, WXT, WebExtension-API, etc.)

module type RuntimeBindings = {
  type sender
  let sendMessage: 'a => Promise.t<'b>
  module OnMessage: {
    let addListener: (('a, sender, 'b => unit) => bool) => unit
    let removeListener: (('a, sender, 'b => unit) => bool) => unit
  }
  let getRuntimeId: unit => option<string>

  // Port capabilities
  type port
  let connect: (~extensionId: string=?, ~name: string=?) => option<port>
  let connectToTab: (~tabId: int, ~frameId: int=?, ~name: string=?) => option<port>

  module Port: {
    let postMessage: (port, 'a) => result<unit, string>
    let disconnect: port => unit
    let name: port => option<string>
    let sender: port => option<'sender>

    module OnMessage: {
      let addListener: (port, 'a => unit) => result<unit, string>
      let removeListener: (port, 'a => unit) => result<unit, string>
    }

    module OnDisconnect: {
      let addListener: (port, port => unit) => result<unit, string>
      let removeListener: (port, port => unit) => result<unit, string>
    }
  }
}

module Make = (Bindings: RuntimeBindings) => {
  // Type-safe handler mapping for removeListener functionality
  let handlerToWrapped: HandlerMap.t = HandlerMap.make()

  let sendMessage:
    type a. Types.message<a> => Promise.t<a> =
    message => {
      if message->MessageChunker.shouldBeChunked {
        let finalResp = ref(None)
        TransportMessage.createChunks(message)
        ->Array.mapWithIndex((chunkTransportMessage, index) => {
          Bindings.sendMessage(chunkTransportMessage)->Promise.thenResolve(response => {
            switch chunkTransportMessage {
            | TransportMessage.FinalChunk(_chunk) => {
                finalResp := Some(response)
                ()
              }
            | TransportMessage.UserMessage(_) => assert(false)
            | TransportMessage.IntermediateChunk(_) => assert(false)
            }
            (index, chunkTransportMessage, response)
          })
        })
        ->Promise.all(_)
        ->Promise.thenResolve(_results => finalResp.contents->Option.getOrThrow)
      } else {
        let transportMessage = TransportMessage.UserMessage(message)
        Bindings.sendMessage(transportMessage)
      }
    }

  // Fire-and-forget message sending (no response expected)
  let cast:
    type a. Types.message<a> => unit =
    message => {
      sendMessage(message)->Promise.ignore
    }

  // Message subscription with automatic chunk reassembly
  module OnMessage = {
    let addListener:
      type a. ((Types.message<a>, Bindings.sender) => Response.t<a>) => unit =
      userResponseHandler => {
        let messageHandler = (transportMessage, sender, sendResponse) => {
          let response = RequestHandler.make(
            ~userHandler=userResponseHandler,
            transportMessage,
            sender,
          )

          // Convert Response.t to Chrome callback pattern
          switch response {
          | Response.RespondNow(value) =>
            sendResponse(value)
            false // Synchronous response
          | Response.RespondLater(promise) =>
            promise
            ->Promise.then(value => {
              sendResponse(value)
              Promise.resolve()
            })
            ->ignore
            true // Asynchronous response
          | Response.NoResponse => false // No response
          }
        }

        // Store mapping for later removal
        HandlerMap.set(handlerToWrapped, userResponseHandler, messageHandler)

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

  // Utility function to check if extension context is still valid
  let isContextValid = () => {
    switch Bindings.getRuntimeId() {
    | Some(_) => true
    | None => false // Context invalidated (extension reload/upgrade)
    }
  }
}
