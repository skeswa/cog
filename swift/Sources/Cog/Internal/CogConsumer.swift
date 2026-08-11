/// Something whose run reads cogs, and so accumulates dependencies.
///
/// A derived cog's selector is the first consumer; reactions and the SwiftUI
/// boundary join it later. What they share is the shape §2.4 describes: while
/// a consumer runs, it is the context's tracked consumer, and every `c.get`
/// during that run links the producer it read to it.
///
/// The protocol is deliberately one method wide. Node storage is
/// heterogeneous and so is the set of things that can consume, so linking has
/// to be spelled across the existential rather than recovered by casting to a
/// concrete consumer kind.
@MainActor
internal protocol CogConsumer: AnyObject {
  /// Records that this consumer read `producer` during the run in progress.
  ///
  /// Called once per tracked read, in read order. Reusing and removing edges
  /// across runs is the recapture work in `M1-06aa` and `M1-09a`; today a run
  /// starts from an empty list and appends what it reads.
  func recordDependency(on producer: any CogNode)
}

// MARK: - The tracking slot

extension Cogtext {
  /// Runs `body` with `consumer` installed as this context's tracked consumer.
  ///
  /// The slot is saved and restored rather than cleared, because consumer runs
  /// nest: reading a derived cog from inside another selector computes the
  /// inner cog, and the inner run must attach its own reads to itself and then
  /// hand tracking back to the outer one. A `defer` restores it even when the
  /// selector exits early.
  ///
  /// One slot rather than a parameter threaded through every read is what §2.4
  /// specifies, and it is what lets a read that never saw the consumer — a
  /// reaction body, a SwiftUI `body` — still be tracked once those callers
  /// exist.
  internal func tracking<Result>(_ consumer: any CogConsumer, _ body: () -> Result) -> Result {
    let enclosing = trackedConsumer
    trackedConsumer = consumer
    defer { trackedConsumer = enclosing }
    return body()
  }

  /// Fails unless `consumer` is the one whose run is in progress right now.
  ///
  /// A ``Reader`` is a value, so nothing in the type system stops a selector
  /// from stashing the one it was handed and using it after its run is over —
  /// the read equivalent of the escaped writer ``Writer`` guards against with a
  /// turn ID. An escaped reader is worse than useless: its reads would attach
  /// dependencies to a node that is not computing, quietly corrupting the graph
  /// in a way that shows up much later as a value that stopped updating. The
  /// tracking slot already knows who is running, so the check is one identity
  /// comparison, and it fails loudly instead.
  ///
  /// `fatalError` rather than `preconditionFailure`, for the reason
  /// ``Writer``'s escaped-writer guard gives: an optimized
  /// `preconditionFailure` drops its message, so a release crash would say
  /// nothing at all, while `fatalError` prints the same sentence in every
  /// configuration. Being un-strippable under `-Ounchecked` is also the right
  /// posture for a capability check.
  internal func requireTracking(_ consumer: any CogConsumer) {
    guard let tracked = trackedConsumer, tracked === consumer else {
      fatalError("A Cog reader is valid only inside the selector run that handed it out.")
    }
  }
}
