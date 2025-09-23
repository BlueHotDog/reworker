/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Unit tests for Response module
// Testing runtime promise behavior and error handling

// Test helper to create test promises
let createTestPromise = (value, delay) => {
  Promise.make((resolve, _reject) => {
    setTimeout(() => {
      resolve(value)
    }, delay)->ignore
  })
}

let createFailingPromise = (error, delay) => {
  Promise.make((_resolve, reject) => {
    setTimeout(() => {
      reject(error)
    }, delay)->ignore
  })
}

// Test: Promise resolution timing (async test)
let testPromiseResolutionTiming = async () => {
  let startTime = Date.now()
  let delay = 50
  let expectedValue = "delayed response"

  let promise = createTestPromise(expectedValue, delay)
  let response = Response.later(promise)

  switch response {
  | Response.RespondLater(resultPromise) =>
    try {
      let result = await resultPromise
      let endTime = Date.now()
      let elapsed = endTime -. startTime

      if result === expectedValue && elapsed >= Int.toFloat(delay - 10) {
        Console.log(`PASS: Promise resolved correctly after ${elapsed->Float.toString}ms`)
        true
      } else {
        Console.error("FAIL: Promise resolution timing or value incorrect")
        Console.log(`Expected: ${expectedValue}, Got: ${result}`)
        Console.log(`Expected delay: ~${delay->Int.toString}ms, Got: ${elapsed->Float.toString}ms`)
        false
      }
    } catch {
    | error =>
      Console.error2("FAIL: Promise resolution threw error:", error)
      false
    }
  | _ =>
    Console.error("FAIL: Not a RespondLater response")
    false
  }
}

// Test: Promise rejection handling (async test)
let testPromiseRejectionHandling = async () => {
  let delay = 30
  let expectedError = "test error"

  let promise = createFailingPromise(expectedError, delay)
  let response = Response.later(promise)

  switch response {
  | Response.RespondLater(resultPromise) =>
    try {
      let _result = await resultPromise
      Console.error("FAIL: Promise should have rejected")
      false
    } catch {
    | error =>
      Console.error2("PASS: Promise rejection handled correctly", error)
      true
    }
  | _ =>
    Console.error("FAIL: Not a RespondLater response")
    false
  }
}

// Run all tests
let runTests = async () => {
  let tests = [
    ("Promise resolution timing", testPromiseResolutionTiming),
    ("Promise rejection handling", testPromiseRejectionHandling),
  ]

  await TestUtils.runAsyncTests("Response Unit Tests", tests)
}

// Export for running
let main = runTests
