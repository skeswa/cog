import Testing

@testable import CogStorefront

/// The standard interaction trace, run end to end on the smoke profile.
///
/// This is the correctness gate every reported number depends on. A benchmark
/// preconditions on the same checkpoints before it prints anything, so a
/// failure here is a failure there — the difference is only that this suite
/// reports each failed claim by name instead of trapping on the first.
@Suite("Storefront session")
@MainActor
struct StorefrontSessionTests {
  @Test("the standard trace holds every checkpoint on the smoke profile")
  func smokeTraceHoldsEveryCheckpoint() async throws {
    let driver = StorefrontSessionDriver(profile: .smoke)
    try await driver.runStandardTrace()

    for checkpoint in driver.checkpoints {
      #expect(checkpoint.holds, "\(checkpoint.failureDescription)")
    }
    #expect(driver.checkpoints.count >= 25, "the trace should make many claims, not a few")
  }

  /// The standard profile's *cold start* runs here; its whole trace does not.
  ///
  /// A full standard session is 27 seconds of unoptimized Swift and about a
  /// quarter of a second in release, so putting it in a debug unit suite would
  /// buy one more assertion at the cost of every other test's turnaround. It is
  /// not skipped, though: `perf-15-storefront-session` runs the same trace in
  /// release and calls `requireCheckpointsHold()` before it reports a number,
  /// so no measurement of the standard profile is ever published without every
  /// checkpoint holding.
  @Test("a standard cold start holds every checkpoint")
  func standardColdStartHoldsEveryCheckpoint() async throws {
    let driver = StorefrontSessionDriver(profile: .standard)
    try await driver.runColdStart()

    for checkpoint in driver.checkpoints {
      #expect(checkpoint.holds, "\(checkpoint.failureDescription)")
    }
    #expect(driver.sink.visibleProductIDs.count == StorefrontProfile.standard.viewportRowCount)
  }

  @Test("a cold start materializes the first screen and nothing more")
  func coldStartMaterializesOneScreen() async throws {
    let driver = StorefrontSessionDriver(profile: .smoke)
    try await driver.runColdStart()

    for checkpoint in driver.checkpoints {
      #expect(checkpoint.holds, "\(checkpoint.failureDescription)")
    }
    #expect(driver.sink.visibleProductIDs.count == StorefrontProfile.smoke.viewportRowCount)
  }
}
