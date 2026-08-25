/// A stable integer name for one value in a runtime-comparison graph.
///
/// The comparison workloads traffic in names rather than backend objects so
/// the exact same graph-building code reaches Cog, raw Observation, and the
/// swift-state-graph adapter that follows in M6-11b. Keeping the name to one
/// integer also prevents type erasure from pricing one backend differently.
@MainActor
struct RuntimeComparisonValue: Hashable {
  /// Position of the value in its adapter's flat node storage.
  let index: Int
}

/// The read capability passed to a comparison computation.
///
/// This is the common denominator between Cog's explicit ``Reader``, raw
/// Swift property access, and swift-state-graph's ambient tracked read. A
/// workload can therefore describe its dependencies once without smuggling a
/// backend-specific value into the measured closure.
@MainActor
struct RuntimeComparisonReader {
  /// Backend-specific tracked-read operation for this computation.
  private let readValue: @MainActor (RuntimeComparisonValue) -> Int

  /// Creates a reader around one backend's dependency-recording operation.
  init(
    readValue: @escaping @MainActor (RuntimeComparisonValue) -> Int
  ) {
    self.readValue = readValue
  }

  /// Reads one value as a dependency of the computation in progress.
  subscript(value: RuntimeComparisonValue) -> Int { readValue(value) }
}

/// The small signal-runtime surface shared by every PERF-10 adapter.
///
/// It deliberately mirrors the primitives used by `js-reactivity-benchmark`:
/// a mutable value, an automatic value, a root read, and a write boundary. It does
/// not require effects because Cog's counted ports keep their roots hot by
/// reading them after each write. That pull shape lets raw Observation remain
/// genuinely raw instead of hiding a bespoke invalidation graph behind it.
@MainActor
protocol RuntimeComparisonGraph: AnyObject {
  /// Makes a mutable value with the supplied initial state.
  func source(_ initialValue: Int) -> RuntimeComparisonValue

  /// Makes an automatic value whose reads flow through the adapter's tracker.
  func automatic(
    _ compute: @escaping @MainActor (RuntimeComparisonReader) -> Int
  ) -> RuntimeComparisonValue

  /// Reads and settles a root after the graph has been built or changed.
  func read(_ value: RuntimeComparisonValue) -> Int

  /// Writes a source through the backend's normal mutation boundary.
  func write(_ value: RuntimeComparisonValue, to newValue: Int)

  /// Returns the exact computation count this backend should spend on a
  /// workload when behaving correctly.
  func expectedRuns(for workload: RuntimeComparisonWorkload) -> Int
}

/// The four Kairo shapes used for the pinned runtime comparison.
///
/// Parameters match the shared `_CogScenarios` ports. The enum is `Sendable`
/// so benchmark registration can capture a case in upstream's `@Sendable`
/// measurement closure without carrying any actor-isolated graph state.
nonisolated enum RuntimeComparisonWorkload: String, CaseIterable, Sendable {
  /// One source, five parallel computations, and one shared sum.
  case diamond

  /// One source followed by a fifty-computation chain.
  case deep

  /// Fifty independent two-computation arms off one source.
  case broad

  /// One consumer that flips between two branches on every turn.
  case unstable

  /// Runs this shape through one adapter and returns its checked accounting.
  @MainActor
  func run(on graph: any RuntimeComparisonGraph) -> RuntimeComparisonResult {
    let counter = RuntimeComparisonCounter()
    let finalValue: Int

    switch self {
    case .diamond:
      finalValue = runDiamond(on: graph, counter: counter)
    case .deep:
      finalValue = runDeep(on: graph, counter: counter)
    case .broad:
      finalValue = runBroad(on: graph, counter: counter)
    case .unstable:
      finalValue = runUnstable(on: graph, counter: counter)
    }

    return RuntimeComparisonResult(
      workload: self,
      actualRuns: counter.runs,
      expectedRuns: graph.expectedRuns(for: self),
      finalValue: finalValue,
      expectedFinalValue: expectedFinalValue
    )
  }

  /// The arithmetic result both backends must produce after their last turn.
  private var expectedFinalValue: Int {
    switch self {
    case .diamond: 5 * (500 + 1)
    case .deep: 50 + 50
    case .broad: 50 + 50
    case .unstable: -20 * 100
    }
  }

  /// Builds and drives Kairo's five-arm diamond.
  @MainActor
  private func runDiamond(
    on graph: any RuntimeComparisonGraph,
    counter: RuntimeComparisonCounter
  ) -> Int {
    let width = 5
    let turns = 500
    let source = graph.source(0)
    let arms = (0..<width).map { _ in
      graph.automatic { c in
        counter.record()
        return c[source] + 1
      }
    }
    let sum = graph.automatic { c in
      counter.record()
      return arms.reduce(0) { $0 + c[$1] }
    }

    var result = graph.read(sum)
    for turn in 1...turns {
      graph.write(source, to: turn)
      result = graph.read(sum)
    }
    return result
  }

  /// Builds and drives Kairo's fifty-link chain.
  @MainActor
  private func runDeep(
    on graph: any RuntimeComparisonGraph,
    counter: RuntimeComparisonCounter
  ) -> Int {
    let depth = 50
    let turns = 50
    let source = graph.source(0)
    var tail = source
    for _ in 0..<depth {
      let below = tail
      tail = graph.automatic { c in
        counter.record()
        return c[below] + 1
      }
    }

    var result = graph.read(tail)
    for turn in 1...turns {
      graph.write(source, to: turn)
      result = graph.read(tail)
    }
    return result
  }

  /// Builds and drives Kairo's fifty independent two-link arms.
  @MainActor
  private func runBroad(
    on graph: any RuntimeComparisonGraph,
    counter: RuntimeComparisonCounter
  ) -> Int {
    let width = 50
    let turns = 50
    let source = graph.source(0)
    let leaves = (0..<width).map { arm in
      let offset = graph.automatic { c in
        counter.record()
        return c[source] + arm
      }
      return graph.automatic { c in
        counter.record()
        return c[offset] + 1
      }
    }

    var result = width
    for leaf in leaves { result = graph.read(leaf) }
    for turn in 1...turns {
      graph.write(source, to: turn)
      for leaf in leaves { result = graph.read(leaf) }
    }
    return result
  }

  /// Builds and drives Kairo's parity-dependent unstable consumer.
  @MainActor
  private func runUnstable(
    on graph: any RuntimeComparisonGraph,
    counter: RuntimeComparisonCounter
  ) -> Int {
    let iterations = 20
    let turns = 100
    let source = graph.source(0)
    let doubled = graph.automatic { c in
      counter.record()
      return c[source] * 2
    }
    let inverse = graph.automatic { c in
      counter.record()
      return -c[source]
    }
    let sum = graph.automatic { c in
      counter.record()
      let head = c[source]
      var result = 0
      for _ in 0..<iterations {
        result += head.isMultiple(of: 2) ? c[inverse] : c[doubled]
      }
      return result
    }

    var result = graph.read(sum)
    for turn in 1...turns {
      graph.write(source, to: turn)
      result = graph.read(sum)
    }
    return result
  }
}

/// Correctness evidence produced alongside one timing sample.
///
/// Final values are common across adapters. Computation counts are allowed to
/// describe real semantic differences: Cog memoizes automatic reads and settles
/// one previously recorded unstable dependency, while raw Observation offers
/// no computed-value cache and therefore evaluates every repeated read.
nonisolated struct RuntimeComparisonResult: Sendable {
  /// Graph shape that produced the result.
  let workload: RuntimeComparisonWorkload

  /// Automatic-body invocations observed during the run.
  let actualRuns: Int

  /// Exact invocations required by this adapter's semantics.
  let expectedRuns: Int

  /// Value returned by the last root read.
  let finalValue: Int

  /// Backend-independent arithmetic result the shape requires.
  let expectedFinalValue: Int

  /// Fails before a number can be reported for an incorrect computation.
  func check() {
    precondition(
      finalValue == expectedFinalValue,
      "\(workload.rawValue) returned \(finalValue); expected \(expectedFinalValue)."
    )
    precondition(
      actualRuns == expectedRuns,
      "\(workload.rawValue) ran \(actualRuns) computations; expected \(expectedRuns)."
    )
  }
}

/// Mutable run counter shared by the closures in one comparison graph.
@MainActor
private final class RuntimeComparisonCounter {
  /// Number of automatic bodies invoked so far.
  private(set) var runs = 0

  /// Records one automatic-body invocation.
  func record() { runs += 1 }
}
