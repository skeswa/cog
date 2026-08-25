import StorefrontWorkload
import Testing

@testable import CogStorefront

/// The standard interaction trace, run end to end on the smoke profile against
/// the Cog runtime.
///
/// This is the detailed correctness gate every reported Cog number depends on.
/// The trace itself is runtime-neutral and lives in `StorefrontWorkload`; what
/// this suite pins is that `CogStorefrontRuntime` satisfies it, including the
/// eleven checkpoints that assert against the semantics Cog declares. The three
/// comparison runtimes prove the same thing in their own packages, against the
/// same script.
///
/// Benchmarks keep these deliberately expensive phase checks outside their
/// measured regions and validate each sample's final shadow digest and exact
/// request quiescence after timing instead.
@Suite("Cog Storefront runtime")
@MainActor
struct CogStorefrontRuntimeTests {
  @Test("the standard trace holds every checkpoint on the smoke profile")
  func smokeTraceHoldsEveryCheckpoint() async throws {
    let driver = StorefrontSessionDriver<CogStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    for checkpoint in driver.checkpoints {
      #expect(checkpoint.holds, "\(checkpoint.failureDescription)")
    }
    #expect(driver.checkpoints.count >= 25, "the trace should make many claims, not a few")
  }

  /// Cog is held to every claim the trace can make, with nothing skipped.
  ///
  /// The skip path exists for runtimes that declare no per-generation refresh
  /// handle and no lifetime release. Cog declares both, so a skip appearing
  /// here would mean the reference runtime had quietly stopped being asserted
  /// against the sharpest two checkpoints in the trace — which a "every
  /// checkpoint holds" loop cannot detect, because a skip holds by
  /// construction.
  @Test("the reference runtime skips no checkpoint")
  func referenceRuntimeSkipsNothing() async throws {
    let driver = StorefrontSessionDriver<CogStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    let skipped = driver.checkpoints.filter { $0.expected.hasPrefix("not applicable:") }
    #expect(skipped.isEmpty, "Cog skipped \(skipped.map(\.name))")
    #expect(driver.checkpoints.contains { $0.name == "superseded refresh" })
    #expect(driver.checkpoints.contains { $0.name == "released row asks again" })
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
    let driver = StorefrontSessionDriver<CogStorefrontRuntime>(profile: .standard)
    try await driver.runColdStart()

    for checkpoint in driver.checkpoints {
      #expect(checkpoint.holds, "\(checkpoint.failureDescription)")
    }
    #expect(driver.sink.visibleProductIDs.count == StorefrontProfile.standard.viewportRowCount)
  }

  @Test("draining immediately includes selected tasks that have not begun")
  func immediateDrainSeesScheduledRequests() async throws {
    let driver = StorefrontSessionDriver<CogStorefrontRuntime>(profile: .smoke)

    let released = try await driver.drainRequests()

    #expect(released > 0)
    #expect(await driver.service.script.outstandingCount == 0)
  }
}
