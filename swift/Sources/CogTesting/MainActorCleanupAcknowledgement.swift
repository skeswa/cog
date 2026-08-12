/// A one-shot signal that MainActor cleanup reached its stopping point.
///
/// Cleanup triggered off executor must reach the MainActor before touching
/// Cog. The cleanup calls ``acknowledge()`` when finished, and the test awaits
/// ``wait()``.
///
/// The signal is buffered, so cleanup may finish before the test starts
/// waiting. Make one acknowledgement per cleanup event and call each method at
/// most once.
public nonisolated final class MainActorCleanupAcknowledgement: Sendable {
  private let events: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  /// Whether cleanup has signalled this acknowledgement.
  ///
  /// This is a diagnostic snapshot for assertions, not a synchronization
  /// primitive. Await ``wait()`` instead of polling it.
  @MainActor public private(set) var hasBeenAcknowledged = false

  public init() {
    (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  /// Records that cleanup reached the MainActor and finished its actor-bound
  /// work.
  @MainActor
  public func acknowledge() {
    hasBeenAcknowledged = true
    continuation.yield()
  }

  /// Suspends until ``acknowledge()`` records this cleanup event.
  ///
  /// - Throws: ``CancellationError`` if the waiting task is cancelled first.
  public func wait() async throws {
    var iterator = events.makeAsyncIterator()
    guard await iterator.next() != nil else {
      throw CancellationError()
    }
  }
}
