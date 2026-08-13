/// A synchronous selector or reaction that records the cogs it reads.
///
/// During a run, each `c[valueReference]` links its producer to the tracked
/// consumer. Async selectors leave this protocol's tracking scope when they
/// return ``Work``; the later work body cannot silently add dependencies after
/// suspension. SwiftUI uses observation boundaries rather than extending this
/// synchronous tracking interval. A consumer strongly owns its last producer
/// list while each producer keeps only a weak reverse subscriber edge, avoiding
/// ownership cycles. All reconciliation occurs synchronously on the MainActor.
@MainActor
internal protocol CogConsumer: AnyObject {
  /// Records that this consumer read `producer` during the run in progress.
  ///
  /// Called once per tracked read, in read order. Every run starts from an empty
  /// list, appends what it reads, and removes reverse edges for producers the
  /// completed run did not read again. This replacement model makes branches
  /// dynamic: only the path taken by the latest completed selector can
  /// invalidate the consumer.
  func recordDependency(on producer: any CogState)

  /// Drops strong producer ownership before the context releases its state map.
  ///
  /// The correctness core stores dependency edges as state references. A deep
  /// linear graph therefore also forms a deep strong-ownership chain, which
  /// ARC could otherwise destroy recursively after the context released its
  /// dictionary entries. The context calls this for every consumer first, so
  /// later property teardown is flat even when graph traversal was deep.
  /// Because the entire graph is ending, implementations do not need to repair
  /// reverse edges as they do for one state's lifetime release.
  func releaseDependenciesForContextTeardown()
}

/// A tracked state that can hand ``Reader`` its previous typed value.
///
/// The outer optional records whether a previous value exists; it must not
/// collapse a real optional `nil`. Async state uses the same contract to expose
/// its previously published metadata to `Reader.curr` machinery. The value belongs
/// to the consumer's latest completed selector run; a reader may consult it only
/// while that same consumer occupies the context tracking slot.
@MainActor
internal protocol CogReaderState<Value>: CogConsumer {
  /// The typed value this consumer caches for `Reader.curr`.
  associatedtype Value

  /// The previous completed value, with the outer optional representing absence.
  var readerCurrentValue: Value? { get }
}

// MARK: - The tracking slot

extension Cogs {
  /// Runs `body` with `consumer` installed as this context's tracked consumer.
  ///
  /// Nested selectors replace the slot for their run, then restore the outer
  /// consumer in `defer`. Saving and restoring instead of using one global
  /// collector ensures a nested derived read attaches its own producers to
  /// itself, while the outer selector records only the nested derived state.
  internal func tracking<Result>(_ consumer: any CogConsumer, _ body: () -> Result) -> Result {
    let enclosing = trackedConsumer
    trackedConsumer = consumer
    defer { trackedConsumer = enclosing }
    return body()
  }

  /// Fails unless `consumer` is the one whose run is in progress right now.
  ///
  /// A saved reader or an async work body could otherwise attach dependencies
  /// after synchronous selection ends. Compare object identity with the
  /// tracking slot and trap before corrupting the graph or making dependency
  /// capture depend on suspension timing.
  ///
  /// `fatalError` preserves the message under `-O` and `-Ounchecked`.
  internal func requireTracking(_ consumer: any CogConsumer) {
    guard let tracked = trackedConsumer, tracked === consumer else {
      fatalError("A Cog reader is valid only inside the selector run that handed it out.")
    }
  }
}
