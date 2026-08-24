import Benchmark
internal import Cog
import CogTesting

/// MainActor cell updated by one durable benchmark reaction.
@MainActor
private final class EdgeLayoutValueSink {
  /// Latest value delivered after the graph finished its turn.
  var value = 0
}

/// Assembly registration that keeps one benchmark root durably observed.
///
/// The arena vertical slice has not migrated Swift Observation boundaries yet,
/// so a tracked `cogs[root]` read still belongs to the class core. A mechanism
/// reaction already crosses the transitional arena bridge correctly and holds
/// a durable lease, avoiding both that unfinished boundary and `peek`'s grace
/// sleeper inside the measured region.
@MainActor
private struct EdgeLayoutObserverMechanism: Mechanism {
  /// Unique assembly attribution within the benchmark context.
  let name: String

  /// Automatic arena value whose completed turns the sink receives.
  let valueReference: Cog<Int>

  /// Stable terminal cell read after each synchronous turn flush.
  let sink: EdgeLayoutValueSink

  /// Registers one reaction whose initial run settles the graph before return.
  func operate(_ m: MechanismController) {
    m.run { c in sink.value = c[valueReference] }
  }
}

/// Fixed-width graphs that isolate stable reuse from dependency-list churn.
///
/// Both roots read one control followed by 32 data sources, so the selected
/// edge storage traverses the same 33 entries per selector run. The mostly
/// static root always reads the same sources. The churn root preserves only
/// its control prefix and replaces all 32 later entries every turn. Keeping
/// both contexts alive makes the measured regions quiescent: they neither drop
/// a `Cogs` nor schedule grace work, so process-global allocation and ARC
/// counters remain valid under the rule M5-11 established.
@MainActor
enum EdgeLayoutHarness {
  /// Data dependencies each selector reads after its stable control.
  static let dependencyWidth = 32

  /// Mostly-static sources, declared once so only values move between turns.
  static let _staticCogs: [Cog<Int>.Manual] = (0..<dependencyWidth).map { index in
    Cog<Int>.Manual({ index }, name: "perf.edge.static.source.\(index)")
  }

  /// Stable first dependency, matching the churn graph's control position.
  static let _staticControlCog = Cog<Int>.Manual({ 0 }, name: "perf.edge.static.control")

  /// One wide consumer whose dependency order never changes.
  static let staticRootCog = Cog<Int>(
    { c in
      var total = c[EdgeLayoutHarness._staticControlCog]
      for sourceCog in EdgeLayoutHarness._staticCogs {
        total &+= c[sourceCog]
      }
      return total
    },
    name: "perf.edge.static.root"
  )

  /// Context holding the settled mostly-static graph across every sample.
  static var staticCogs: Cogs?

  /// Reaction terminal carrying the latest mostly-static root value.
  private static let staticSink = EdgeLayoutValueSink()

  /// Expected value of the mostly-static root after the latest turn.
  static var staticExpected = 0

  /// Monotonic turn counter used to rotate which stable source changes.
  static var staticTurn = 0

  /// Number of available sources the churn window rotates through.
  static let churnSourceCount = 128

  /// Fixed data values; only the root's selected window changes.
  static let _churnCogs: [Cog<Int>.Manual] = (0..<churnSourceCount).map { index in
    Cog<Int>.Manual({ index + 1 }, name: "perf.edge.churn.source.\(index)")
  }

  /// Stable first dependency whose value chooses the 32-entry window.
  static let _churnControlCog = Cog<Int>.Manual({ 0 }, name: "perf.edge.churn.control")

  /// One wide consumer that replaces its complete non-control suffix per turn.
  static let churnRootCog = Cog<Int>(
    { c in
      let start = c[EdgeLayoutHarness._churnControlCog]
      var total = 0
      for offset in 0..<EdgeLayoutHarness.dependencyWidth {
        let index = (start + offset) % EdgeLayoutHarness.churnSourceCount
        total &+= c[EdgeLayoutHarness._churnCogs[index]]
      }
      return total
    },
    name: "perf.edge.churn.root"
  )

  /// Expected churn-root sums indexed by the selected window start.
  static let churnExpected: [Int] = (0..<churnSourceCount).map { start in
    (0..<dependencyWidth).reduce(0) { total, offset in
      total &+ ((start + offset) % churnSourceCount + 1)
    }
  }

  /// Context holding the settled high-churn graph across every sample.
  static var churnCogs: Cogs?

  /// Reaction terminal carrying the latest high-churn root value.
  private static let churnSink = EdgeLayoutValueSink()

  /// Monotonic control value; modulo chooses the current source window.
  static var churnTurn = 0

  /// Builds and settles the mostly-static graph outside measurement.
  static func settleMostlyStatic() {
    guard staticCogs == nil else { return }
    let context = Cogs.forTesting(mechanisms: [
      EdgeLayoutObserverMechanism(
        name: "EdgeStatic",
        valueReference: staticRootCog,
        sink: staticSink
      )
    ])
    let initial = staticSink.value
    let expected = (0..<dependencyWidth).reduce(0, &+)
    precondition(initial == expected, "The mostly-static edge benchmark settled incorrectly.")
    staticExpected = expected
    staticCogs = context
  }

  /// Changes values without ever changing the root's dependency identities.
  static func runMostlyStaticTurns(_ count: Int) {
    guard let cogs = staticCogs else {
      fatalError("The mostly-static edge benchmark ran before setup.")
    }

    var result = staticExpected
    for _ in 0..<max(count, 1) {
      staticTurn &+= 1
      let index = staticTurn % dependencyWidth
      cogs.turn("perf.edge.static.turn") { c in
        c[_staticCogs[index]] &+= dependencyWidth
      }
      staticExpected &+= dependencyWidth
      result = staticSink.value
    }

    precondition(result == staticExpected, "The mostly-static edge benchmark drifted.")
    blackHole(result)
  }

  /// Builds and settles the rotating-window graph outside measurement.
  static func settleHighChurn() {
    guard churnCogs == nil else { return }
    let context = Cogs.forTesting(mechanisms: [
      EdgeLayoutObserverMechanism(
        name: "EdgeChurn",
        valueReference: churnRootCog,
        sink: churnSink
      )
    ])
    let initial = churnSink.value
    precondition(initial == churnExpected[0], "The high-churn edge benchmark settled incorrectly.")
    churnCogs = context
  }

  /// Preserves the control edge and replaces every overflow dependency each turn.
  static func runHighChurnTurns(_ count: Int) {
    guard let cogs = churnCogs else {
      fatalError("The high-churn edge benchmark ran before setup.")
    }

    var result = churnExpected[churnTurn % churnSourceCount]
    for _ in 0..<max(count, 1) {
      churnTurn &+= 1
      cogs.turn(_churnControlCog, to: churnTurn, name: "perf.edge.churn.turn")
      result = churnSink.value
    }

    let expected = churnExpected[churnTurn % churnSourceCount]
    precondition(result == expected, "The high-churn edge benchmark drifted.")
    blackHole(result)
  }
}

/// Registers the two exact-name PERF-09 workloads on the selected edge pool.
let edgeLayoutBenchmarks: @Sendable () -> Void = {
  let metrics: [BenchmarkMetric] = [
    .wallClock, .instructions, .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount,
  ]
  let reported = BenchmarkThresholds()
  let thresholds: [BenchmarkMetric: BenchmarkThresholds] = Dictionary(
    uniqueKeysWithValues: metrics.map { ($0, reported) }
  )

  Benchmark(
    "perf-09-edge-mostly-static",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: thresholds
    )
  ) { benchmark in
    await EdgeLayoutHarness.settleMostlyStatic()
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await EdgeLayoutHarness.runMostlyStaticTurns(count)
    benchmark.stopMeasurement()
  }

  Benchmark(
    "perf-09-edge-high-churn",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: thresholds
    )
  ) { benchmark in
    await EdgeLayoutHarness.settleHighChurn()
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await EdgeLayoutHarness.runHighChurnTurns(count)
    benchmark.stopMeasurement()
  }
}
