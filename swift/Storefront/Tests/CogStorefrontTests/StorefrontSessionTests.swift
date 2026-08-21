import Testing

@testable import CogStorefront

/// The standard interaction trace, run end to end on the smoke profile.
///
/// This is the detailed correctness gate every reported number depends on.
/// Benchmarks keep these deliberately expensive phase checks outside their
/// measured regions and validate each sample's final shadow digest and exact
/// request quiescence after timing instead.
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
  /// release, and this suite proves the complete trace semantics on the
  /// structurally identical smoke profile while the benchmark validates each
  /// standard-profile sample's final shadow digest after timing.
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

  @Test("draining immediately includes selected tasks that have not begun")
  func immediateDrainSeesScheduledRequests() async throws {
    let driver = StorefrontSessionDriver(profile: .smoke)

    let released = try await driver.drainRequests()

    #expect(released > 0)
    #expect(await driver.service.script.outstandingCount == 0)
  }

  @Test("an early release consumes the synchronously scheduled request")
  func earlyReleaseConsumesScheduledRequest() async throws {
    let script = StorefrontScript(mode: .scripted)
    script.schedule(.catalog)

    #expect(await script.pendingRequestIDs == [.catalog])
    #expect(await script.outstandingCount == 1)
    await script.release(.catalog)
    try await script.begin(.catalog)

    #expect(await script.startCount(of: .catalog) == 1)
    #expect(await script.outstandingCount == 0)
  }
}
