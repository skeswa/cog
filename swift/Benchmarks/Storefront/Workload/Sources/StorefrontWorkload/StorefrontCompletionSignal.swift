/// A one-shot MainActor barrier a runtime fires when it has finished deciding
/// about one asynchronous result.
///
/// The analogue of Cog's `MainActorCleanupAcknowledgement`, for ports that
/// cannot import `CogTesting`. Deliberately valueless: a waiter learns that a
/// decision *happened*, never what it was, because a decision to discard a
/// stale result is exactly as much of a signal as a decision to publish one.
///
/// ## Structure
///
/// One `AsyncStream` buffering the newest single element, which is exactly the
/// shape `MainActorCleanupAcknowledgement` uses. The mirroring is deliberate
/// and load-bearing rather than incidental: the Cog adapter fires Cog's
/// primitive and every other port fires this one, so a difference in how the
/// two resolve an already-delivered event would surface as a flake in one
/// runtime only — the hardest kind of benchmark defect to attribute.
///
/// ## Identity and ownership
///
/// One instance per awaited result, created by the runtime's
/// `settlingOneAsyncResult(_:)` and released once its waiter resumes. It is
/// never reused: a runtime arms a fresh instance for each awaited decision and
/// clears its reference in the epilogue that fires it.
///
/// ## Isolation and ordering
///
/// The class itself is `nonisolated` so a waiter suspended on a task that is
/// not the MainActor can resume without a hop, while ``signal()`` is
/// MainActor-confined because a publish-or-discard decision is a MainActor
/// decision in every runtime. Arming is a MainActor operation and must happen
/// strictly before the release that produces the result, because a scripted
/// release can resume and publish synchronously. Signalling before anyone waits
/// is safe: the buffered event wakes a later ``wait()`` immediately rather than
/// hanging.
///
/// One-shot in both directions. A second ``signal()`` on the same instance
/// traps, because a barrier that silently absorbed a second completion would
/// let a port satisfy a one-result step with two. A second ``wait()`` has no
/// buffered event left to consume and would hang, so make one signal per
/// awaited decision rather than waiting twice on one.
///
/// ## Cancellation
///
/// ``wait()`` throws `CancellationError` when its task is cancelled before the
/// event arrives, so a cancelled trace fails rather than hanging.
///
/// `nonisolated deinit` per the repository convention: a synthesized deinit
/// under `.defaultIsolation(MainActor.self)` would ask the concurrency runtime
/// which executor it is on for every deallocation.
public nonisolated final class StorefrontCompletionSignal: Sendable {
  /// The buffered receive side consumed by the single waiter.
  private let events: AsyncStream<Void>

  /// The send side retained until the runtime publishes the one event.
  private let continuation: AsyncStream<Void>.Continuation

  /// Whether the runtime has already fired this barrier.
  ///
  /// MainActor-confined because ``signal()`` is, which is what makes the
  /// one-shot check a plain read rather than a synchronization problem. This is
  /// the trap's own bookkeeping, not a polling surface: await ``wait()``.
  @MainActor private var hasSignalled = false

  /// Creates an unsignalled, independently buffered barrier.
  public init() {
    (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Records that one decision completed and resumes any waiter.
  ///
  /// Call this from the runtime's own result epilogue, on both the publish and
  /// the discard branch, and exactly once. The buffered event wakes a current
  /// waiter or remains available for a later one.
  ///
  /// Traps on a second call. A benchmark that reported a one-result step
  /// satisfied by two results would be measuring a different workload from the
  /// one it names.
  @MainActor
  public func signal() {
    guard !hasSignalled else {
      fatalError(
        """
        A Storefront completion signal was fired twice. Each awaited asynchronous decision \
        arms its own signal, so a second fire means one release produced two publish-or-discard \
        decisions and the step measured more work than it claims to.
        """
      )
    }
    hasSignalled = true
    continuation.yield()
  }

  /// Suspends until ``signal()`` has been called, or returns immediately if it
  /// already has.
  ///
  /// This consumes the barrier's buffered event, so create another barrier
  /// rather than waiting twice on one decision.
  ///
  /// - Throws: `CancellationError` if the waiting task is cancelled first.
  public func wait() async throws {
    var iterator = events.makeAsyncIterator()
    guard await iterator.next() != nil else {
      throw CancellationError()
    }
  }

  nonisolated deinit {}
}
