import Cog
import CogTesting
import Testing
import os

/// Off-actor controlled work whose runs report cooperative cancellation.
///
/// The lock keeps continuation storage sound while `@concurrent` operations
/// start and finish away from the MainActor.
private nonisolated final class Async36ControlledWork: @unchecked Sendable {
  private struct State {
    var continuations: [Int: CheckedContinuation<Int, Never>] = [:]
  }

  let starts: AsyncStream<Int>
  let cancellations: AsyncStream<Int>

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let startContinuation: AsyncStream<Int>.Continuation
  private let cancellationContinuation: AsyncStream<Int>.Continuation

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
    (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func run(_ run: Int) async -> Int {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        state.withLock { state in
          state.continuations[run] = continuation
        }
        startContinuation.yield(run)
      }
    } onCancel: {
      cancellationContinuation.yield(run)
    }
  }

  func finish(_ run: Int, with value: Int) {
    let continuation = state.withLock { $0.continuations.removeValue(forKey: run) }
    continuation?.resume(returning: value)
  }

  nonisolated deinit {}
}

@MainActor
@Test func `ASYNC-36 replaced concurrent work receives cooperative cancellation`() async {
  // ASYNC-16 proves a stale concurrent result cannot commit; this proves the
  // replaced background task is also told to stop. Without the cancellation
  // request, off-actor work would keep burning until it finished on its own.
  let cogs = Cogs.forTesting()
  let request = ManualCog<Int>(0)
  let work = Async36ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { c in
    let currentRequest = c[request]
    return .run { @concurrent in
      await work.run(currentRequest)
    }
  }
  let (statuses, statusContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  let token = cogs.run { c in statusContinuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  guard await statusIterator.next() != nil else {
    Issue.record("The status stream ended before initial pending")
    return
  }
  #expect(await startIterator.next() == 0)

  cogs.commit("change request") { c in c[request] = 1 }

  // The replaced run is cancelled cooperatively, and the replacement starts.
  #expect(await cancellationIterator.next() == 0)
  guard await statusIterator.next() != nil else {
    Issue.record("The status stream ended before replacement pending")
    return
  }
  #expect(await startIterator.next() == 1)

  work.finish(1, with: 11)
  guard let completed = await statusIterator.next(), completed.kind == .success else {
    Issue.record("The replacement's result did not commit")
    return
  }
  #expect(completed.value == 11)
  withExtendedLifetime(token) {}
}
