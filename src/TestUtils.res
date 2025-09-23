/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Shared test utilities
// Provides common test running patterns to avoid repetition across test files

type testResult = (string, bool)

// Helper to run a single async test
let runAsyncTest = (name: string, testFn: unit => promise<bool>) => {
  Promise.make((resolve, _reject) => {
    Console.log(`\n--- ${name} ---`)
    testFn()
    ->Promise.then(result => {
      resolve(result)
      Promise.resolve()
    })
    ->Promise.catch(error => {
      Console.error2(`ERROR in ${name}:`, error)
      resolve(false)
      Promise.resolve()
    })
    ->ignore
  })
}

// Display test results summary
let displayResults = (results: array<testResult>) => {
  Console.log("\n=== Test Results ===")
  let passedCount = ref(0)

  results->Array.forEach(((name, passed)) => {
    let status = passed ? "✅ PASS" : "❌ FAIL"
    Console.log(`${status}: ${name}`)
    if passed {
      passedCount := passedCount.contents + 1
    }
  })

  let totalTests = results->Array.length
  Console.log(`\nPassed: ${passedCount.contents->Int.toString}/${totalTests->Int.toString}`)

  if passedCount.contents === totalTests {
    Console.log("🎉 All tests passed!")
  } else {
    Console.error("💥 Some tests failed!")
  }
}

// Simple runner for sync-only tests
let runSyncTests = (title: string, tests: array<(string, unit => bool)>) => {
  Console.log(`=== ${title} ===`)

  let results = tests->Array.map(((name, testFn)) => {
    Console.log(`\n--- ${name} ---`)
    let passed = testFn()
    (name, passed)
  })

  displayResults(results)
}

// Combined runner for mixed sync/async tests
let runMixedTests = async (
  title: string,
  syncTests: array<(string, unit => bool)>,
  asyncTests: array<(string, unit => promise<bool>)>,
) => {
  Console.log(`=== ${title} ===`)

  // Run sync tests
  let syncResults = syncTests->Array.map(((name, testFn)) => {
    Console.log(`\n--- ${name} ---`)
    let passed = testFn()
    (name, passed)
  })

  // Run async tests sequentially
  let asyncResults = []
  for i in 0 to asyncTests->Array.length - 1 {
    switch asyncTests[i] {
    | Some((name, testFn)) =>
      let result = await runAsyncTest(name, testFn)
      asyncResults->Array.push((name, result))->ignore
    | None => ()
    }
  }

  // Combine and display results
  let allResults = syncResults->Array.concat(asyncResults)
  displayResults(allResults)
}

// Async-only runner
let runAsyncTests = async (title: string, tests: array<(string, unit => promise<bool>)>) => {
  Console.log(`=== ${title} ===`)

  let results = []
  for i in 0 to tests->Array.length - 1 {
    switch tests[i] {
    | Some((name, testFn)) =>
      let result = await runAsyncTest(name, testFn)
      results->Array.push((name, result))->ignore
    | None => ()
    }
  }

  displayResults(results)
}