/// A selector or reaction that records the cogs it reads.
///
/// During a run, each `c[valueReference]` links its producer to the tracked consumer.
/// SwiftUI will use the same protocol.
@MainActor
internal protocol CogConsumer: AnyObject {
  /// Records that this consumer read `producer` during the run in progress.
  ///
  /// Called once per tracked read, in read order. Every run starts from an
  /// empty list, appends what it reads, and removes reverse edges for producers
  /// the completed run did not read again.
  func recordDependency(on producer: any CogState)

  /// Drops strong producer ownership before the context releases its state map.
  ///
  /// The correctness core stores dependency edges as state references. A deep
  /// linear graph therefore also forms a deep strong-ownership chain, which
  /// ARC could otherwise destroy recursively after the context released its
  /// dictionary entries. The context calls this for every consumer first, so
  /// the later property teardown is flat even when graph traversal was deep.
  func releaseDependenciesForContextTeardown()
}

// MARK: - The tracking slot

extension Cogtext {
  /// Runs `body` with `consumer` installed as this context's tracked consumer.
  ///
  /// Nested selectors replace the slot for their run, then restore the outer
  /// consumer in `defer`. The SwiftUI boundary will use the same slot (§2.4).
  internal func tracking<Result>(_ consumer: any CogConsumer, _ body: () -> Result) -> Result {
    let enclosing = trackedConsumer
    trackedConsumer = consumer
    defer { trackedConsumer = enclosing }
    return body()
  }

  /// Fails unless `consumer` is the one whose run is in progress right now.
  ///
  /// A saved reader could attach dependencies after its selector ends. Compare
  /// object identity with the tracking slot and trap before corrupting the
  /// graph.
  ///
  /// `fatalError` preserves the message under `-O` and `-Ounchecked`.
  internal func requireTracking(_ consumer: any CogConsumer) {
    guard let tracked = trackedConsumer, tracked === consumer else {
      fatalError("A Cog reader is valid only inside the selector run that handed it out.")
    }
  }
}
