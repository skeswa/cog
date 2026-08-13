import Cog
import os

/// A monotonic clock whose time advances only when a test advances it.
///
/// Inject the same instance into application scheduling code and, when testing
/// Cog-owned lifetime timers, ``Cogs/forTesting(clock:whileObservedGrace:)``.
/// Sleeps register deterministically, support concurrent deadlines, and resume
/// in deadline order. No test needs to wait for wall-clock time to trigger a
/// scheduled operation.
public nonisolated final class TestClock: Clock, @unchecked Sendable {
  /// A bounded wait found no newly scheduled sleep.
  public struct WaitTimeout: Error, CustomStringConvertible, Sendable {
    /// A stable diagnostic suitable for test failure output.
    public let description = "no sleep was scheduled on the test clock before the deadline"

    /// Creates the clock's stateless timeout diagnostic.
    public init() {}
  }

  /// One point on the test-controlled monotonic timeline.
  public struct Instant: InstantProtocol, Hashable, Sendable {
    /// Elapsed test time since the clock was created.
    fileprivate let offset: Swift.Duration

    /// Orders instants on the controlled timeline.
    public static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.offset < rhs.offset
    }

    /// Returns an instant displaced by `duration` without changing the clock.
    public func advanced(by duration: Swift.Duration) -> Self {
      Self(offset: offset + duration)
    }

    /// Measures the signed duration from this instant to `other`.
    public func duration(to other: Self) -> Swift.Duration {
      other.offset - offset
    }
  }

  /// The duration representation required by ``Clock``.
  public typealias Duration = Swift.Duration

  /// One task suspended until a controlled deadline.
  private struct Sleeper {
    /// Stable insertion order used to break equal-deadline ties.
    let id: UInt64
    /// The controlled instant that makes the sleep eligible.
    let deadline: Instant
    /// The task continuation resumed by advance, cancellation, or finish.
    let continuation: CheckedContinuation<Void, any Error>
  }

  /// One caller waiting to learn that a task scheduled a sleep.
  private struct ScheduleWaiter {
    /// Stable identity used by cancellation to remove the exact waiter.
    let id: UInt64
    /// The task continuation resumed by scheduling, cancellation, or finish.
    let continuation: CheckedContinuation<Void, any Error>
  }

  /// All mutable clock state guarded by one unfair lock.
  private struct State {
    /// Current controlled time.
    var now = Instant(offset: .zero)
    /// Identity allocated to the next sleep or scheduling waiter.
    var nextID: UInt64 = 0
    /// Deadline sleepers not yet resumed.
    var sleepers: [UInt64: Sleeper] = [:]
    /// Scheduled-sleep signals not yet consumed by a test.
    var unconsumedScheduleSignals = 0
    /// Tests waiting for a future scheduled-sleep signal.
    var scheduleWaiters: [ScheduleWaiter] = []
    /// Whether ``finish()`` has made the clock terminal.
    var isFinished = false

    /// Allocates a never-reused identity or traps before wraparound.
    mutating func allocateID() -> UInt64 {
      guard nextID < UInt64.max else {
        fatalError("TestClock exhausted its waiter identity counter.")
      }
      nextID += 1
      return nextID
    }
  }

  /// The lock providing thread-safe synchronous ``Clock`` requirements.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a live clock at test time zero.
  public init() {}

  /// The current test-controlled instant.
  public var now: Instant {
    state.withLock { $0.now }
  }

  /// The smallest duration this logical clock distinguishes.
  public var minimumResolution: Swift.Duration { .nanoseconds(1) }

  /// Suspends until controlled time reaches `deadline`.
  ///
  /// Cancellation removes the exact registered sleep and throws
  /// ``CancellationError``. Calling this after ``finish()`` does the same.
  public func sleep(
    until deadline: Instant,
    tolerance _: Swift.Duration?
  ) async throws {
    let id = state.withLock { $0.allocateID() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let registration = state.withLock {
          state -> (
            Result<Void, any Error>?, CheckedContinuation<Void, any Error>?
          ) in
          if Task.isCancelled || state.isFinished {
            return (.failure(CancellationError()), nil)
          } else if deadline <= state.now {
            return (.success(()), nil)
          } else {
            state.sleepers[id] = Sleeper(
              id: id,
              deadline: deadline,
              continuation: continuation
            )
            if state.scheduleWaiters.isEmpty {
              state.unconsumedScheduleSignals += 1
              return (nil, nil)
            } else {
              return (nil, state.scheduleWaiters.removeFirst().continuation)
            }
          }
        }
        registration.1?.resume()
        if let immediateResult = registration.0 {
          continuation.resume(with: immediateResult)
        }
      }
    } onCancel: {
      self.cancelSleep(id: id)
    }
  }

  /// Advances controlled time and resumes every newly eligible sleeper.
  ///
  /// Sleepers resume in deadline order, with registration order breaking ties.
  /// Advancing backward is a programmer error and traps in every build.
  ///
  /// - Parameter duration: A nonnegative distance to add to ``now``.
  public func advance(by duration: Swift.Duration) {
    guard duration >= .zero else {
      fatalError("TestClock cannot advance backward.")
    }
    let continuations = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
      guard !state.isFinished else { return [] }
      state.now = state.now.advanced(by: duration)
      let ready = state.sleepers.values
        .filter { $0.deadline <= state.now }
        .sorted {
          ($0.deadline, $0.id) < ($1.deadline, $1.id)
        }
      for sleeper in ready {
        state.sleepers.removeValue(forKey: sleeper.id)
      }
      return ready.map(\.continuation)
    }
    for continuation in continuations {
      continuation.resume()
    }
  }

  /// Waits until one task has registered a new future sleep.
  ///
  /// The real-time budget is only a failure bound; it never drives the
  /// controlled clock. This makes a dead scheduling loop fail instead of
  /// hanging the suite indefinitely.
  ///
  /// - Parameter budget: Maximum wall-clock time allowed for registration.
  /// - Throws: ``WaitTimeout`` when no signal arrives within `budget`, or
  ///   ``CancellationError`` when the caller or clock is cancelled.
  public func waitForScheduledSleep(
    within budget: Swift.Duration = .seconds(5)
  ) async throws {
    let scheduled = try await withThrowingTaskGroup(of: Bool.self) { group in
      group.addTask {
        try await self.nextScheduleSignal()
        return true
      }
      group.addTask {
        try await Task.sleep(for: budget)
        return false
      }
      let first = try await group.next() ?? false
      group.cancelAll()
      return first
    }
    guard scheduled else { throw WaitTimeout() }
  }

  /// Cancels every sleeper and makes this clock reject future sleeps.
  ///
  /// Repeated calls do nothing. Finishing is optional when ordinary ownership
  /// already releases all tasks, but explicit cleanup makes test intent clear.
  public func finish() {
    let continuations = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
      guard !state.isFinished else { return [] }
      state.isFinished = true
      let continuations =
        state.sleepers.values.map(\.continuation)
        + state.scheduleWaiters.map(\.continuation)
      state.sleepers.removeAll()
      state.scheduleWaiters.removeAll()
      state.unconsumedScheduleSignals = 0
      return continuations
    }
    for continuation in continuations {
      continuation.resume(throwing: CancellationError())
    }
  }

  /// Removes and cancels one exact deadline sleep.
  private func cancelSleep(id: UInt64) {
    let continuation = state.withLock { state in
      state.sleepers.removeValue(forKey: id)?.continuation
    }
    continuation?.resume(throwing: CancellationError())
  }

  /// Consumes one scheduling signal, suspending if none is buffered.
  private func nextScheduleSignal() async throws {
    let id = state.withLock { $0.allocateID() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let immediateResult = state.withLock { state -> Result<Void, any Error>? in
          if Task.isCancelled || state.isFinished {
            return .failure(CancellationError())
          } else if state.unconsumedScheduleSignals > 0 {
            state.unconsumedScheduleSignals -= 1
            return .success(())
          } else {
            state.scheduleWaiters.append(ScheduleWaiter(id: id, continuation: continuation))
            return nil
          }
        }
        if let immediateResult {
          continuation.resume(with: immediateResult)
        }
      }
    } onCancel: {
      self.cancelScheduleWaiter(id: id)
    }
  }

  /// Removes and cancels one exact scheduling-signal waiter.
  private func cancelScheduleWaiter(id: UInt64) {
    let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
      guard let index = state.scheduleWaiters.firstIndex(where: { $0.id == id }) else {
        return nil
      }
      return state.scheduleWaiters.remove(at: index).continuation
    }
    continuation?.resume(throwing: CancellationError())
  }

  /// Prevents suspended test tasks from outliving the clock itself.
  deinit {
    finish()
  }
}
