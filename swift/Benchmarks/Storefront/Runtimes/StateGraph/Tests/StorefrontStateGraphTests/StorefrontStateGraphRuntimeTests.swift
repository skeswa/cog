import StorefrontStateGraph
import StorefrontWorkload
import Testing

/// The standard interaction trace, run end to end against the swift-state-graph
/// runtime.
///
/// This is the gate every reported state-graph number depends on. The trace
/// itself is runtime-neutral and lives in `StorefrontWorkload`; what this suite
/// pins is that ``StateGraphStorefrontRuntime`` satisfies it, the same
/// checkpoints, against the same script and the same shadow model, that the Cog
/// reference satisfies in its own package. A comparison benchmark whose port was
/// never held to the reference's own claims would be measuring something nobody
/// checked.
///
/// Not `@testable`: every claim here is about the port's public contract, which
/// is exactly what the neutral trace drives. The memoization suite is the one
/// place this package reaches for an internal symbol, and it greens no
/// checkpoint.
@Suite("swift-state-graph Storefront runtime")
@MainActor
struct StorefrontStateGraphRuntimeTests {
  @Test("the standard trace holds every checkpoint on the smoke profile")
  func smokeTraceHoldsEveryCheckpoint() async throws {
    let driver = StorefrontSessionDriver<StateGraphStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    for checkpoint in driver.checkpoints {
      #expect(checkpoint.holds, "\(checkpoint.failureDescription)")
    }
    #expect(driver.checkpoints.count >= 25, "the trace should make many claims, not a few")
  }

  /// The port is held to every claim the trace can make, with nothing skipped.
  ///
  /// The skip path exists for a runtime that declares no per-generation refresh
  /// handle and no lifetime release. This one declares both, the handles and
  /// the release sweep are hand-written, which is a fact about how much the
  /// port had to supply rather than a reason to be excused from proving them,
  /// so a skip appearing here would mean the two sharpest checkpoints in the
  /// trace had quietly stopped being asserted, which an "every checkpoint holds"
  /// loop cannot detect because a skip holds by construction.
  @Test("the port skips no checkpoint")
  func portSkipsNothing() async throws {
    let driver = StorefrontSessionDriver<StateGraphStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    let skipped = driver.checkpoints.filter { $0.expected.hasPrefix("not applicable:") }
    #expect(skipped.isEmpty, "the state-graph port skipped \(skipped.map(\.name))")
    #expect(driver.checkpoints.contains { $0.name == "superseded refresh" })
    #expect(driver.checkpoints.contains { $0.name == "released row asks again" })
  }

  /// The port settles to the same world the shadow model computed.
  ///
  /// Separate from the checkpoint loop because it is a different kind of claim.
  /// The checkpoints are per phase and several of them read a declared number;
  /// `requireSettledOutput(against:)` reads none, admits no per-runtime
  /// variation, and also proves the session ended with no outstanding
  /// request, so a port that reached the right screen by leaving work in flight
  /// fails here rather than looking correct.
  @Test("the settled session matches the shared shadow and leaves nothing outstanding")
  func settledSessionMatchesTheShadow() async throws {
    let driver = StorefrontSessionDriver<StateGraphStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    await driver.requireSettledOutput()
  }

  /// The standard profile's *cold start* runs here; its whole trace does not.
  ///
  /// Same split as the Cog suite's, for the same reason: a full standard session
  /// in an unoptimized debug build buys one more assertion at the cost of every
  /// other test's turnaround, and the release-configuration benchmark runs the
  /// complete trace anyway. The structurally identical smoke profile proves the
  /// trace semantics; this proves the port survives the reported scale's first
  /// screen.
  @Test("a standard cold start holds every checkpoint")
  func standardColdStartHoldsEveryCheckpoint() async throws {
    let driver = StorefrontSessionDriver<StateGraphStorefrontRuntime>(profile: .standard)
    try await driver.runColdStart()

    for checkpoint in driver.checkpoints {
      #expect(checkpoint.holds, "\(checkpoint.failureDescription)")
    }
    #expect(driver.sink.visibleProductIDs.count == StorefrontProfile.standard.viewportRowCount)
  }

  @Test("draining immediately includes selected tasks that have not begun")
  func immediateDrainSeesScheduledRequests() async throws {
    let driver = StorefrontSessionDriver<StateGraphStorefrontRuntime>(profile: .smoke)

    let released = try await driver.drainRequests()

    #expect(released > 0)
    #expect(await driver.service.script.outstandingCount == 0)
  }
}
