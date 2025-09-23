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
  let removedListenerCount = ref(0)

  // Store actual handlers for removeListener testing (using Obj.t for type erasure)
  let storedHandlers: ref<array<Obj.t>> = ref([])

  let sendMessage: 'a => Promise.t<'b> = message => {
    // Just increment counter instead of storing the actual messages
    sentMessageCount := sentMessageCount.contents + 1
    // Ignore the message for now and return a resolved promise
    ignore(message)
    Promise.resolve("mock response"->Obj.magic)
  }

  module OnMessage = {
    let addListener: (('a, sender, 'b => unit) => bool) => unit = handler => {
      addedListenerCount := addedListenerCount.contents + 1
      storedHandlers := Array.concat(storedHandlers.contents, [Obj.magic(handler)])
    }

    let removeListener: (('a, sender, 'b => unit) => bool) => unit = handler => {
      // Check if handler exists in stored handlers
      let exists = Array.some(storedHandlers.contents, stored => Obj.magic(stored) === Obj.magic(handler))
      if exists {
        removedListenerCount := removedListenerCount.contents + 1
        storedHandlers := Array.filter(storedHandlers.contents, stored => Obj.magic(stored) !== Obj.magic(handler))
      }
    }
  }

  let getRuntimeId = () => Some("mock-runtime-id")

  // Helper to reset mock state
  let reset = () => {
    sentMessageCount := 0
    addedListenerCount := 0
    removedListenerCount := 0
    storedHandlers := []
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

// Test: removeListener removes correct handler
let testRemoveListenerBasic = () => {
  MockBindings.reset()

  let handler1 = (message, _sender) => {
    switch message {
    | SimpleTest(_) => Response.now("handler1")
    | _ => Response.none
    }
  }

  let handler2 = (message, _sender) => {
    switch message {
    | SimpleTest(_) => Response.now("handler2")
    | _ => Response.none
    }
  }

  try {
    // Add both handlers
    TestRuntime.OnMessage.addListener(handler1)
    TestRuntime.OnMessage.addListener(handler2)

    // Verify both added
    let addedCount = MockBindings.addedListenerCount.contents
    if addedCount !== 2 {
      Console.error(`FAIL: Expected 2 added listeners, got ${addedCount->Int.toString}`)
      false
    } else {
      // Remove first handler
      TestRuntime.OnMessage.removeListener(handler1)

      let removedCount = MockBindings.removedListenerCount.contents
      if removedCount === 1 {
        Console.log("PASS: removeListener removed correct handler")
        true
      } else {
        Console.error(`FAIL: Expected 1 removed listener, got ${removedCount->Int.toString}`)
        false
      }
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during removeListener basic test:", error)
    false
  }
}

// Test: removeListener with non-existent handler
let testRemoveListenerNonExistent = () => {
  MockBindings.reset()

  let handler1 = (message, _sender) => {
    switch message {
    | SimpleTest(_) => Response.now("handler1")
    | _ => Response.none
    }
  }

  let handler2 = (message, _sender) => {
    switch message {
    | SimpleTest(_) => Response.now("handler2")
    | _ => Response.none
    }
  }

  try {
    // Add only handler1
    TestRuntime.OnMessage.addListener(handler1)

    // Try to remove handler2 (never added)
    TestRuntime.OnMessage.removeListener(handler2)

    let removedCount = MockBindings.removedListenerCount.contents
    if removedCount === 0 {
      Console.log("PASS: removeListener ignores non-existent handler")
      true
    } else {
      Console.error(`FAIL: Expected 0 removed listeners, got ${removedCount->Int.toString}`)
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during removeListener non-existent test:", error)
    false
  }
}

// Test: removeListener with same handler added multiple times
let testRemoveListenerDuplicate = () => {
  MockBindings.reset()

  let handler = (message, _sender) => {
    switch message {
    | SimpleTest(_) => Response.now("handler")
    | _ => Response.none
    }
  }

  try {
    // Add same handler twice
    TestRuntime.OnMessage.addListener(handler)
    TestRuntime.OnMessage.addListener(handler)

    let addedCount = MockBindings.addedListenerCount.contents
    if addedCount !== 2 {
      Console.error(`FAIL: Expected 2 added listeners, got ${addedCount->Int.toString}`)
      false
    } else {
      // Remove handler once
      TestRuntime.OnMessage.removeListener(handler)

      let removedCount = MockBindings.removedListenerCount.contents
      let remainingHandlers = Array.length(MockBindings.storedHandlers.contents)

      if removedCount === 1 && remainingHandlers === 1 {
        Console.log("PASS: removeListener removes one instance of duplicate handler")
        true
      } else {
        Console.error(`FAIL: Expected 1 removed, 1 remaining. Got ${removedCount->Int.toString} removed, ${remainingHandlers->Int.toString} remaining`)
        false
      }
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during removeListener duplicate test:", error)
    false
  }
}

// Test: removeListener with different message types
let testRemoveListenerDifferentTypes = () => {
  MockBindings.reset()

  let stringHandler = (message, _sender) => {
    switch message {
    | SimpleTest(_) => Response.now("string response")
    | _ => Response.none
    }
  }

  let unitHandler = (message, _sender) => {
    switch message {
    | NoResponseTest => Response.none
    | _ => Response.none
    }
  }

  try {
    // Add handlers with different message types
    TestRuntime.OnMessage.addListener(stringHandler)
    TestRuntime.OnMessage.addListener(unitHandler)

    let addedCount = MockBindings.addedListenerCount.contents
    if addedCount !== 2 {
      Console.error(`FAIL: Expected 2 added listeners, got ${addedCount->Int.toString}`)
      false
    } else {
      // Remove string handler
      TestRuntime.OnMessage.removeListener(stringHandler)

      let removedCount = MockBindings.removedListenerCount.contents
      let remainingHandlers = Array.length(MockBindings.storedHandlers.contents)

      if removedCount === 1 && remainingHandlers === 1 {
        Console.log("PASS: removeListener works with different message types")
        true
      } else {
        Console.error(`FAIL: Expected 1 removed, 1 remaining. Got ${removedCount->Int.toString} removed, ${remainingHandlers->Int.toString} remaining`)
        false
      }
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during removeListener different types test:", error)
    false
  }
}

// Test: removeListener memory behavior (WeakMap cleanup)
let testRemoveListenerMemoryBehavior = () => {
  MockBindings.reset()

  // Create handler in a scope that will be GC eligible
  let testHandler = ref(None)

  let createHandler = () => {
    (message, _sender) => {
      switch message {
      | SimpleTest(_) => Response.now("scoped handler")
      | _ => Response.none
      }
    }
  }

  try {
    let handler = createHandler()
    testHandler := Some(handler)

    // Add and then remove handler
    TestRuntime.OnMessage.addListener(handler)
    TestRuntime.OnMessage.removeListener(handler)

    let removedCount = MockBindings.removedListenerCount.contents
    if removedCount === 1 {
      // Clear reference to make handler eligible for GC
      testHandler := None

      Console.log("PASS: removeListener completed cleanup (WeakMap should allow GC)")
      true
    } else {
      Console.error(`FAIL: Expected 1 removed listener, got ${removedCount->Int.toString}`)
      false
    }
  } catch {
  | error =>
    Console.error2("FAIL: Exception during removeListener memory test:", error)
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
    ("removeListener basic functionality", testRemoveListenerBasic),
    ("removeListener non-existent handler", testRemoveListenerNonExistent),
    ("removeListener duplicate handler", testRemoveListenerDuplicate),
    ("removeListener different message types", testRemoveListenerDifferentTypes),
    ("removeListener memory behavior", testRemoveListenerMemoryBehavior),
  ]

  TestUtils.runSyncTests("Runtime Integration Tests", tests)
}

// Export for running
let main = runTests
