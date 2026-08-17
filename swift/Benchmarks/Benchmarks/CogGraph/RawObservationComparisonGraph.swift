import Observation

/// One stored property instrumented by Swift's Observation macro.
///
/// Only mutable values use storage because raw Observation does not provide a
/// derived-value graph or memoization primitive. Derived adapter nodes are
/// ordinary closures; their reads still reach this accessor and therefore pay
/// the registrar access that an `@Observable` model pays in application code.
@MainActor
@Observable
private final class RawObservationSource {
  /// The source value reached by derived and root reads.
  var value: Int

  /// Creates one independently registered observable property.
  init(_ value: Int) { self.value = value }
}

/// One value in the honest raw-Observation adapter.
@MainActor
private enum RawObservationNode {
  /// A macro-instrumented stored property.
  case source(RawObservationSource)

  /// An uncached Swift computation, because Observation supplies no cache.
  case derived(@MainActor (RuntimeComparisonReader) -> Int)
}

/// PERF-10's raw `@Observable` lower-bound adapter.
///
/// This adapter intentionally does not grow a hand-built dirty graph around
/// Observation. Such a graph would benchmark that implementation rather than
/// the standard-library registrar. A source maps to an `@Observable` stored
/// property, a derived value maps to an ordinary computed read, a root read is
/// tracked with `withObservationTracking`, and a write maps to ordinary
/// property assignment. The shared run counter makes the resulting lack of
/// memoization explicit instead of letting it hide in a slower timing number.
@MainActor
final class RawObservationComparisonGraph: RuntimeComparisonGraph {
  /// Nodes in creation order; integer comparison names index this array.
  private var nodes: [RawObservationNode] = []

  /// Makes one macro-instrumented stored property.
  func source(_ initialValue: Int) -> RuntimeComparisonValue {
    let value = RuntimeComparisonValue(index: nodes.count)
    nodes.append(.source(RawObservationSource(initialValue)))
    return value
  }

  /// Makes one uncached computed read.
  func derived(
    _ compute: @escaping @MainActor (RuntimeComparisonReader) -> Int
  ) -> RuntimeComparisonValue {
    let value = RuntimeComparisonValue(index: nodes.count)
    nodes.append(.derived(compute))
    return value
  }

  /// Evaluates a root under the same tracking scope SwiftUI establishes.
  ///
  /// The empty callback is intentional: the benchmark driver pulls the root
  /// after each completed write, just as it does for Cog. Observation still
  /// registers every accessed key path and notifies that registration on the
  /// next write, so both halves of the registrar cost remain in the sample
  /// without adding an asynchronous scheduler that no compared graph uses.
  func read(_ value: RuntimeComparisonValue) -> Int {
    withObservationTracking {
      evaluate(value)
    } onChange: {
    }
  }

  /// Recursively evaluates one source or uncached computation inside the
  /// outer root's single Observation tracking scope.
  private func evaluate(_ value: RuntimeComparisonValue) -> Int {
    switch nodes[value.index] {
    case .source(let source): return source.value
    case .derived(let compute):
      return compute(
        RuntimeComparisonReader { [unowned self] dependency in
          self.evaluate(dependency)
        }
      )
    }
  }

  /// Assigns one macro-instrumented stored property directly.
  func write(_ value: RuntimeComparisonValue, to newValue: Int) {
    guard case .source(let source) = nodes[value.index] else {
      fatalError("The raw Observation comparison tried to write a computed value.")
    }
    source.value = newValue
  }

  /// Counts ordinary computed-property evaluation for each Kairo shape.
  func expectedRuns(for workload: RuntimeComparisonWorkload) -> Int {
    switch workload {
    case .diamond: (5 + 1) * (1 + 500)
    case .deep: 50 * (1 + 50)
    case .broad: 2 * 50 * (1 + 50)
    case .unstable: (20 + 1) * (1 + 100)
    }
  }
}
