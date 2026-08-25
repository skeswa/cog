public import StorefrontWorkload

/// This port's per-generation demand handle.
///
/// Handed back by
/// ``MemoObservationStorefrontRuntime/refreshRecommendations()`` and bound to
/// *that* demand: a later demand resolves this one as
/// ``StorefrontRefreshOutcome/superseded`` at the moment of replacement, not
/// when its task eventually finishes, and a lifetime release resolves it as
/// ``StorefrontRefreshOutcome/released``. That is what makes replacement a
/// definite signal the teardown phase can await without a clock, a poll, or a
/// timeout.
///
/// A `struct` wrapping a MainActor-isolated resolution cell, so copying a handle
/// shares the one resolution rather than forking it, and so ``Sendable``
/// conformance costs nothing: a global-actor-isolated class is `Sendable`, and
/// the outcome is resolved on the MainActor where every publish decision in
/// this port is made.
public struct MemoObservationRefresh: StorefrontRefreshHandle {
  /// What this generation produced.
  public typealias Value = [ProductID]

  /// The cell this handle reads its one resolution out of.
  private let cell: MemoObservationRefreshCell

  /// Wraps one resolution cell.
  ///
  /// - Parameter cell: The cell the runtime resolves when this exact
  ///   generation succeeds, fails, is replaced, or is released.
  init(cell: MemoObservationRefreshCell) {
    self.cell = cell
  }

  /// The terminal result of this exact generation.
  ///
  /// Suspends until the runtime resolves the generation, and returns
  /// immediately once it has. Awaiting after the runtime has long moved on is
  /// safe and still answers about the generation this handle names, because the
  /// cell retains its resolution.
  public var outcome: StorefrontRefreshOutcome<[ProductID]> {
    get async { await cell.resolution() }
  }
}

/// One demand generation's resolution, and the waiters queued on it.
///
/// Separated from ``MemoObservationRefresh`` because the handle is a value that
/// may be copied and the resolution is a fact that must not be: two copies of a
/// handle name one generation and must observe one outcome.
///
/// ## Isolation and ordering
///
/// MainActor-confined, because ``resolve(_:)`` is called from exactly the
/// places a publish-or-discard decision is made — the runtime's own asynchronous
/// epilogue, its replacement path, and its lifetime sweep — and all three are
/// MainActor code. ``resolution()`` suspends on the MainActor rather than
/// blocking it, so a trace awaiting a superseded handle does not stop the
/// runtime from superseding it.
///
/// One-shot: the first ``resolve(_:)`` wins and later ones are ignored, because
/// a generation that has already been declared superseded cannot later be
/// declared released without the trace's checkpoint comparing a word to a word
/// that changed underneath it.
///
/// `nonisolated deinit` per the repository convention.
final class MemoObservationRefreshCell {
  /// The resolution, once there is one.
  private var resolved: StorefrontRefreshOutcome<[ProductID]>?

  /// Everyone awaiting this generation, in arrival order.
  private var waiters: [CheckedContinuation<StorefrontRefreshOutcome<[ProductID]>, Never>] = []

  /// Creates an unresolved cell.
  init() {}

  /// Records this generation's terminal result and resumes every waiter.
  ///
  /// Idempotent after the first call, so a released cell whose task later
  /// completes does not rewrite the answer a checkpoint has already read.
  ///
  /// - Parameter outcome: What this generation produced.
  func resolve(_ outcome: StorefrontRefreshOutcome<[ProductID]>) {
    guard resolved == nil else { return }
    resolved = outcome
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume(returning: outcome) }
  }

  /// The terminal result, awaiting it if it has not happened yet.
  ///
  /// - Returns: What this generation produced.
  func resolution() async -> StorefrontRefreshOutcome<[ProductID]> {
    if let resolved { return resolved }
    return await withCheckedContinuation { continuation in
      if let resolved {
        continuation.resume(returning: resolved)
      } else {
        waiters.append(continuation)
      }
    }
  }

  nonisolated deinit {}
}
