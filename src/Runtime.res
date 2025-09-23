/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Generic Runtime wrapper for message passing with automatic chunking
// Users provide their own messaging bindings (WebWorker, ServiceWorker, WXT, WebExtension-API, etc.)

module type RuntimeBindings = {
  type sender
  let sendMessage: ('a, 'b => unit) => unit
  module OnMessage: {
    let addListener: (('a, sender, 'b => unit) => bool) => unit
    let removeListener: (('a, sender, 'b => unit) => bool) => unit
  }

  // Runtime ID for context validation
  let getRuntimeId: unit => option<string>
}

module Make = (Bindings: RuntimeBindings) => {
  module HandlerMap = RequestHandler__Map

  let sendMessage:
    type a. (Types.message<a>, a => unit) => unit =
    (message, responseHandler) => {
      if message->MessageChunker.shouldBeChunked {
        let chunks = TransportMessage.createChunks(message)
        chunks->Array.forEach(chunkTransportMessage => {
          switch chunkTransportMessage {
          | TransportMessage.IntermediateChunk(chunk) =>
            Bindings.sendMessage(chunkTransportMessage, chunkAck => {
              switch chunkAck {
              | TransportMessage.ChunkAck(ackId)
                if ackId === chunk->TransportMessage.Chunk.messageId => ()
              | _ => assert(false)
              }
            })

          | TransportMessage.FinalChunk(_chunk) =>
            Bindings.sendMessage(chunkTransportMessage, originalResponse => {
              responseHandler(originalResponse)
            })

          | TransportMessage.UserMessage(_) => assert(false) // Should not happen in chunk array
          }
        })
      } else {
        // Send message directly as transport message
        let transportMessage = TransportMessage.UserMessage(message)
        Bindings.sendMessage(transportMessage, originalResponse => {
          responseHandler(originalResponse)
        })
      }
    }

  // Fire-and-forget message sending (no response expected)
  let cast:
    type a. Types.message<a> => unit =
    message => {
      sendMessage(message, _response => ())
    }

  // Message subscription with automatic chunk reassembly
  module OnMessage = {
    let addListener:
      type a. ((Types.message<a>, Bindings.sender) => Response.t<a>) => unit =
      userResponseHandler => {
        let messageHandler = (transportMessage, sender, sendResponse) => {
          let response = RequestHandler.make(~userHandler=userResponseHandler, transportMessage, sender)

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

        Bindings.OnMessage.addListener(messageHandler)
      }

    let removeListener:
      type a. ((Types.message<a>, Bindings.sender) => Response.t<a>) => unit =
      _handler => {
        // Note: This is tricky because we need to track the wrapped handler
        // For now, we'll warn that this isn't fully supported
        Console.warn("removeListener not fully supported - manage listeners in your bindings")
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
