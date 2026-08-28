/// A one-shot MainActor barrier a runtime fires when it has finished deciding
/// about one asynchronous result.
///
/// The non-Cog counterpart to `MainActorCleanupAcknowledgement`. It reports that
/// a publish or discard decision finished, but carries no value.
///
/// ## Structure
///
/// Uses the same one-element `AsyncStream` shape as Cog's barrier. This keeps
/// delivery order equal across all ports.
///
/// ## Identity and ownership
///
/// One instance per awaited result, created by the runtime's
/// `settlingOneAsyncResult(_:)` and released once its waiter resumes. It is
/// never reused. Each decision gets a fresh instance that its epilogue clears.
///
/// ## Isolation and ordering
///
/// The class is `nonisolated`, while ``signal()`` stays on the MainActor with
/// publish decisions. Arm it before releasing work because release may publish
/// at once. Its buffer also supports signalling before ``wait()``.
///
/// One-shot in both directions. A second ``signal()`` on the same instance
/// traps so two completions cannot satisfy one-result work. A second ``wait()``
/// has no event, so use one barrier per decision.
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
