import Observation
internal import StateGraph

/// Flat ownership for swift-state-graph's stored and computed nodes.
///
/// A `Computed` rule is `@Sendable` and may outlive the adapter call that
/// creates it. Each rule therefore captures this storage `unowned`, while the
/// graph owns both the storage and all nodes. That avoids a permanent cycle and
/// makes the deep workload release one flat array instead of a recursive chain.
@MainActor
private final class StateGraphComparisonStorage {
  /// Every source and computed node in creation order.
  var nodes: [StateGraphComparisonNode] = []

  /// Reads one node through swift-state-graph's ambient dependency tracker.
  func read(_ value: RuntimeComparisonValue) -> Int {
    switch nodes[value.index] {
    case .source(let source): source.wrappedValue
    case .automatic(let automatic): automatic.wrappedValue
    }
  }
}

/// One swift-state-graph node stored behind a common comparison name.
@MainActor
private enum StateGraphComparisonNode {
  /// A mutable `Stored<Int>` source.
  case source(Stored<Int>)

  /// A memoized `Computed<Int>` value.
  case automatic(Computed<Int>)
}

/// PERF-10 adapter for swift-state-graph 0.28.0.
///
/// The mapping stays on the library's primitive surface: `Stored` for mutable
/// values, `Computed` for automatic values, `wrappedValue` for tracked reads, and
/// `withGraphTransaction` for the write boundary. Root reads also sit
/// under Swift Observation tracking, matching the Cog and raw-Observation
/// adapters' UI-facing read scope.
@MainActor
final class StateGraphRuntimeComparisonGraph: RuntimeComparisonGraph {
  /// Flat node storage shared with every computed rule.
  private let storage = StateGraphComparisonStorage()

  /// Makes an equality-gated swift-state-graph source.
  func source(_ initialValue: Int) -> RuntimeComparisonValue {
    let value = RuntimeComparisonValue(index: storage.nodes.count)
    storage.nodes.append(
      .source(Stored<Int>(name: "perf.compare.source", wrappedValue: initialValue))
    )
    return value
  }

  /// Makes a memoized computed node using ambient tracked reads.
  ///
  /// StateGraph's rule is nonisolated and `@Sendable`, while this benchmark is
  /// structurally MainActor-confined. `assumeIsolated` documents and checks
  /// that synchronous invariant at the one crossing point; StateGraph invokes
  /// the rule from the root read performed by this adapter on the MainActor.
  func automatic(
    _ compute: @escaping @MainActor (RuntimeComparisonReader) -> Int
  ) -> RuntimeComparisonValue {
    let value = RuntimeComparisonValue(index: storage.nodes.count)
    let storage = storage
    let automatic = Computed<Int>(name: "perf.compare.automatic") { [unowned storage] _ in
      MainActor.assumeIsolated {
        compute(
          RuntimeComparisonReader { dependency in
            storage.read(dependency)
          }
        )
      }
    }
    storage.nodes.append(.automatic(automatic))
    return value
  }

  /// Pulls a root through StateGraph's Observation-compatible accessor.
  func read(_ value: RuntimeComparisonValue) -> Int {
    withObservationTracking {
      storage.read(value)
    } onChange: {
    }
  }

  /// Stages and publishes one source assignment as a graph transaction.
  func write(_ value: RuntimeComparisonValue, to newValue: Int) {
    guard case .source(let source) = storage.nodes[value.index] else {
      fatalError("The swift-state-graph comparison tried to write a computed value.")
    }
    withGraphTransaction {
      source.wrappedValue = newValue
    }
  }

  /// Returns the exact memoized-work expectations for the four shared shapes.
  func expectedRuns(for workload: RuntimeComparisonWorkload) -> Int {
    switch workload {
    case .diamond: (5 + 1) * (1 + 500)
    case .deep: 50 * (1 + 50)
    case .broad: 2 * 50 * (1 + 50)
    case .unstable: 2 + 3 * 100
    }
  }
}
