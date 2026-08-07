/*
 * Copyright 2025 BlueHotDog
 * SPDX-License-Identifier: MIT
 */

// Test runner for all reworker tests
// Executes all test suites and provides summary

let runAllTests = async () => {
  Console.log("🧪 ReWorker Test Suite")
  Console.log("="->String.repeat(50))

  let startTime = Date.now()

  // Track overall results
  let totalSuites = ref(0)
  let passedSuites = ref(0)

  // Helper to run a test suite and track results
  let runSuite = (suiteName, testRunner) => {
    totalSuites := totalSuites.contents + 1
    Console.log(`\n🔍 Running ${suiteName}...`)

    try {
      if testRunner() {
        passedSuites := passedSuites.contents + 1
        Console.log(`✅ ${suiteName} completed`)
      }
    } catch {
    | error => Console.error2(`❌ ${suiteName} failed with error:`, error)
    }
  }

  // Helper to run async test suite
  let runAsyncSuite = async (suiteName, testRunner) => {
    totalSuites := totalSuites.contents + 1
    Console.log(`\n🔍 Running ${suiteName}...`)

    try {
      if await testRunner() {
        passedSuites := passedSuites.contents + 1
        Console.log(`✅ ${suiteName} completed`)
      }
    } catch {
    | error => Console.error2(`❌ ${suiteName} failed with error:`, error)
    }
  }

  // Run all test suites
  runSuite("MessageChunker Unit Tests", MessageChunker__test.main)
  runSuite("TransportMessage Unit Tests", TransportMessage__test.main)
  await runAsyncSuite("Response Unit Tests", Response__test.main)
  await runAsyncSuite("Runtime Integration Tests", Runtime__test.main)

  // Calculate elapsed time
  let endTime = Date.now()
  let elapsed = endTime - startTime

  // Print summary
  Console.log("\n" ++ "="->String.repeat(50))
  Console.log("📊 Test Suite Summary")
  Console.log("="->String.repeat(50))

  let passedCount = passedSuites.contents
  let totalCount = totalSuites.contents
  let passRate = if totalCount > 0 {
    (passedCount->Int.toFloat / totalCount->Int.toFloat * 100.0)->Float.toString
  } else {
    "0"
  }

  Console.log(
    `Suites passed: ${passedCount->Int.toString}/${totalCount->Int.toString} (${passRate}%)`,
  )
  Console.log(`Total time: ${elapsed->Float.toString}ms`)

  if passedCount === totalCount {
    Console.log("🎉 All test suites passed!")
    Console.log("\n✨ ReWorker library is ready for production!")
  } else {
    Console.error("💥 Some test suites failed!")
    Console.log("\n🔧 Please review and fix failing tests before using the library.")
    JsError.make("Test suite failed")->JsError.throw
  }

  Console.log("="->String.repeat(50))
}

runAllTests()->ignore
