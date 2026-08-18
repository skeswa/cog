internal import Cog
import CogTesting
import Observation

/// Flat ownership for the Cog adapter's declarations.
///
/// Derived descriptors capture this storage `unowned`, while the graph owns
/// both it and the runtime. That breaks the otherwise permanent cycle in which
/// the storage owns a descriptor whose selector owns the storage, and it also
/// makes teardown flat rather than recursive for the deep workload.
@MainActor
private final class CogComparisonStorage {
  /// Every source and derived declaration in creation order.
  var nodes: [CogComparisonNode] = []

  /// Reads one stored declaration through the selector's explicit reader.
  func read(_ value: RuntimeComparisonValue, through reader: Reader<Int>) -> Int {
    switch nodes[value.index] {
    case .source(let source): reader[source]
    case .derived(let derived): reader[derived]
    }
  }
}

/// One Cog declaration stored behind a common comparison name.
@MainActor
private enum CogComparisonNode {
  /// A writable Cog source.
  case source(ManualCog<Int>)

  /// A memoized Cog computation.
  case derived(Cog<Int>)
}

/// PERF-10 adapter for either Cog core selected by `COG_TEST_CORE`.
///
/// The benchmark package is rebuilt once with `simple` and once with `arena`;
/// the public declarations stay identical, so the adapter needs no core
/// branch of its own. Its explicit reader bridge is the only place the common
/// workload meets Cog's dependency-capture API.
@MainActor
final class CogRuntimeComparisonGraph: RuntimeComparisonGraph {
  /// Isolated runtime that owns all state created for this sample.
  private let cogs = Cogs.forTesting()

  /// Flat declaration storage shared with derived selectors.
  private let storage = CogComparisonStorage()

  /// Makes a Cog manual declaration.
  func source(_ initialValue: Int) -> RuntimeComparisonValue {
    let value = RuntimeComparisonValue(index: storage.nodes.count)
    storage.nodes.append(
      .source(ManualCog<Int>(initialValue, name: "perf.compare.source.\(value.index)"))
    )
    return value
  }

  /// Makes a Cog derived declaration and bridges its explicit reader.
  func derived(
    _ compute: @escaping @MainActor (RuntimeComparisonReader) -> Int
  ) -> RuntimeComparisonValue {
    let value = RuntimeComparisonValue(index: storage.nodes.count)
    let storage = storage
    let derived = Cog<Int>(
      { [unowned storage] reader in
        compute(
          RuntimeComparisonReader { dependency in
            storage.read(dependency, through: reader)
          }
        )
      },
      name: "perf.compare.derived.\(value.index)"
    )
    storage.nodes.append(.derived(derived))
    return value
  }

  /// Pulls a root under the same tracking scope used by the raw adapter.
  ///
  /// This reaches Cog's public UI boundary rather than `peek`: PERF-10 compares
  /// a complete tracked read, and using the one-shot API here would add Cog's
  /// transient-lifetime grace sleeper while raw Observation registers a UI
  /// consumer. The empty callback is enough to exercise registration and the
  /// next turn's invalidation; the common driver performs the following pull.
  func read(_ value: RuntimeComparisonValue) -> Int {
    switch storage.nodes[value.index] {
    case .source(let source):
      return withObservationTracking {
        cogs[source]
      } onChange: {
      }
    case .derived(let derived):
      return withObservationTracking {
        cogs[derived]
      } onChange: {
      }
    }
  }

  /// Commits a source write as one Cog turn.
  func write(_ value: RuntimeComparisonValue, to newValue: Int) {
    guard case .source(let source) = storage.nodes[value.index] else {
      fatalError("The runtime comparison tried to write a derived Cog value.")
    }
    cogs.commit(source, to: newValue, name: "perf.compare.turn")
  }

  /// Returns the counted expectations already proved by COUNT-01–COUNT-04.
  func expectedRuns(for workload: RuntimeComparisonWorkload) -> Int {
    switch workload {
    case .diamond: (5 + 1) * (1 + 500)
    case .deep: 50 * (1 + 50)
    case .broad: 2 * 50 * (1 + 50)
    case .unstable: 2 + 3 * 100
    }
  }
}
