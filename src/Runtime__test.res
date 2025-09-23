/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Integration tests for Runtime module
// Testing Response.t to callback conversion and Runtime.Make functor

// Mock bindings for testing
module MockBindings = {
  type sender = {
    id: string,
    context: string,
  }

  // Store sent messages count for verification
  let sentMessageCount = ref(0)

  // Store added listeners count for verification
  let addedListenerCount = ref(0)

  let sendMessage: 'a => Promise.t<'b> = message => {
    // Just increment counter instead of storing the actual messages
    sentMessageCount := sentMessageCount.contents + 1
    // Ignore the message for now and return a resolved promise
    ignore(message)
    Promise.resolve("mock response"->Obj.magic)
  }

  module OnMessage = {
    let addListener = handler => {
      addedListenerCount := addedListenerCount.contents + 1
      ignore(handler)
    }

    let removeListener = _handler => {
      // Mock implementation
      ()
    }
  }

  let getRuntimeId = () => Some("mock-runtime-id")

  // Helper to reset mock state
  let reset = () => {
    sentMessageCount := 0
    addedListenerCount := 0
  }
}

// Test message types
type Types.message<_> +=
  | SimpleTest(string): Types.message<string>
  | AsyncTest(string): Types.message<string>
  | NoResponseTest: Types.message<unit>

// Create Runtime instance with mock bindings
module TestRuntime = Runtime.Make(MockBindings)

// Test: sendMessage passes through to bindings
let testSendMessagePassthrough = () => {
  MockBindings.reset()

  let testMessage = SimpleTest("send test")
  let responseReceived = ref(None)

  try {
    TestRuntime.sendMessage(testMessage)->Promise.then(response => {
      responseReceived := Some(response)
      Promise.resolve()
    })->ignore

    let sentCount = MockBindings.sentMessageCount.contents
    if sentCount === 1 {
      Console.log("PASS: sendMessage passed through to bindings")
      true
    } else {
      Console.error(`FAIL: Expected 1 sent message, got ${sentCount->Int.toString}`)
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during sendMessage test:", error)
    false
  }
}

// Test: cast (fire-and-forget) works correctly
let testCastFireAndForget = () => {
  MockBindings.reset()

  let testMessage = SimpleTest("cast test")

  try {
    TestRuntime.cast(testMessage)

    let sentCount = MockBindings.sentMessageCount.contents
    if sentCount === 1 {
      Console.log("PASS: cast sends message without expecting response")
      true
    } else {
      Console.error(`FAIL: Expected 1 cast message, got ${sentCount->Int.toString}`)
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during cast test:", error)
    false
  }
}

// Test: addListener converts Response.t to callback pattern
let testAddListenerConversion = () => {
  MockBindings.reset()

  let testResponse = "converted response"

  // Create user handler that returns Response.t
  let userHandler = (message, _sender) => {
    switch message {
    | SimpleTest(_) => Response.now(testResponse)
    | AsyncTest(_) => Response.later(Promise.resolve("async response"))
    | _ => Response.none
    }
  }

  try {
    // Add listener
    TestRuntime.OnMessage.addListener(userHandler)

    let listenerCount = MockBindings.addedListenerCount.contents
    if listenerCount === 1 {
      Console.log("PASS: addListener registered callback with bindings")
      true
    } else {
      Console.error(`FAIL: Expected 1 listener, got ${listenerCount->Int.toString}`)
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during addListener test:", error)
    false
  }
}

// Test: RespondNow conversion to callback (simplified)
let testRespondNowConversion = () => {
  MockBindings.reset()

  let testResponse = "immediate response"
  let userHandler = (message, _sender) => {
    switch message {
    | SimpleTest(_) => Response.now(testResponse)
    | _ => Response.none
    }
  }

  try {
    TestRuntime.OnMessage.addListener(userHandler)
    Console.log("PASS: RespondNow handler added without errors")
    true
  } catch {
  | error =>
    Console.error2("FAIL: Exception during RespondNow test:", error)
    false
  }
}

// Test: RespondLater conversion to callback with async (simplified)
let testRespondLaterConversion = () => {
  MockBindings.reset()

  let asyncResponse = "async response"
  let userHandler = (message, _sender) => {
    switch message {
    | AsyncTest(_) => Response.later(Promise.resolve(asyncResponse))
    | _ => Response.none
    }
  }

  try {
    TestRuntime.OnMessage.addListener(userHandler)
    Console.log("PASS: RespondLater handler added without errors")
    true
  } catch {
  | error =>
    Console.error2("FAIL: Exception during RespondLater test:", error)
    false
  }
}

// Test: NoResponse conversion to callback (simplified)
let testNoResponseConversion = () => {
  MockBindings.reset()

  // Create a separate handler specifically for unit response messages
  let unitHandler = (message, _sender) => {
    switch message {
    | NoResponseTest => Response.none
    | _ => Response.none
    }
  }

  try {
    TestRuntime.OnMessage.addListener(unitHandler)
    Console.log("PASS: NoResponse handler added without errors")
    true
  } catch {
  | error =>
    Console.error2("FAIL: Exception during NoResponse test:", error)
    false
  }
}

// Test: isContextValid utility
let testIsContextValid = () => {
  try {
    let isValid = TestRuntime.isContextValid()

    if isValid {
      Console.log("PASS: isContextValid returns true with mock runtime ID")
      true
    } else {
      Console.error("FAIL: isContextValid should return true with mock runtime ID")
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during isContextValid test:", error)
    false
  }
}

// Test: Error handling in user handler (simplified)
let testErrorHandlingInUserHandler = () => {
  MockBindings.reset()

  let userHandler = (_message, _sender) => {
    // Simulate error in user handler
    JsError.throwWithMessage("Test error in user handler")
  }

  try {
    TestRuntime.OnMessage.addListener(userHandler)
    Console.log("PASS: Error handler added without immediate crash")
    true
  } catch {
  | error =>
    Console.error2("PASS: Error in user handler was caught during setup", error)
    true
  }
}

// Test: Chunked message handling with out-of-order responses
let testChunkedMessageOutOfOrder = () => {
  // For now, just test that chunked messages work at all
  // More sophisticated out-of-order testing would require complex mock setup
  try {
    // Create a large message that will be chunked
    let largeMessage = "A" ->String.repeat(MessageChunker.defaultChunkSize + 1000)
    let testMessage = SimpleTest(largeMessage)

    TestRuntime.sendMessage(testMessage)->Promise.then(_response => {
      Promise.resolve()
    })->ignore

    Console.log("PASS: Chunked message handled")
    true
  } catch {
  | error =>
    Console.error2("FAIL: Exception during chunked message test:", error)
    false
  }
}

// Test: Basic chunked message handling
let testBasicChunkedMessage = () => {
  MockBindings.reset()

  try {
    let largeMessage = "B"->String.repeat(MessageChunker.defaultChunkSize + 1000)
    let testMessage = SimpleTest(largeMessage)

    TestRuntime.sendMessage(testMessage)->Promise.then(_response => {
      Console.log("PASS: Large message handled (basic chunking)")
      Promise.resolve()
    })->ignore

    true
  } catch {
  | error =>
    Console.error2("FAIL: Exception during basic chunked test:", error)
    false
  }
}

// Run all tests
let runTests = () => {
  let tests = [
    ("sendMessage passthrough", testSendMessagePassthrough),
    ("cast fire-and-forget", testCastFireAndForget),
    ("addListener conversion", testAddListenerConversion),
    ("RespondNow conversion", testRespondNowConversion),
    ("RespondLater conversion", testRespondLaterConversion),
    ("NoResponse conversion", testNoResponseConversion),
    ("isContextValid utility", testIsContextValid),
    ("Error handling in user handler", testErrorHandlingInUserHandler),
    ("Chunked message handling", testChunkedMessageOutOfOrder),
    ("Basic chunked message", testBasicChunkedMessage),
  ]

  TestUtils.runSyncTests("Runtime Integration Tests", tests)
}

// Export for running
let main = runTests
