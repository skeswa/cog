public import StorefrontWorkload

/// This port's per-generation demand handle.
///
/// ``MemoObservationStorefrontRuntime/refreshRecommendations()`` returns this
/// handle for one demand. Replacement resolves it as
/// ``StorefrontRefreshOutcome/superseded`` at once. Lifetime release resolves it
/// as ``StorefrontRefreshOutcome/released``. Teardown can await either result
/// without a clock, poll, or timeout.
///
/// This `struct` wraps one MainActor-isolated resolution cell. Copies share one
/// result. The cell is `Sendable`, and the runtime resolves it where all publish
/// decisions occur.
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
/// Separate from the value handle so all copies observe one generation result.
///
/// ## Isolation and ordering
///
/// MainActor-confined because the async epilogue, replacement path, and lifetime
/// sweep resolve it there. ``resolution()`` suspends without blocking the actor.
///
/// One-shot: the first ``resolve(_:)`` wins, so the outcome cannot change after
/// a checkpoint reads it.
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
