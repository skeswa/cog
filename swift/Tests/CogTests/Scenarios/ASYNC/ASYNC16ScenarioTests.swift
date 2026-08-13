import Cog
import CogTesting
import Testing
import os

private nonisolated struct Async16Run: Sendable, Equatable {
  let request: Int
  let ranWithoutActorIsolation: Bool
}

private nonisolated final class Async16ControlledWork: @unchecked Sendable {
  private struct State {
    var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
  }

  let starts: AsyncStream<Async16Run>

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let startContinuation: AsyncStream<Async16Run>.Continuation

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Async16Run.self)
  }

  func run(_ run: Async16Run) async -> Async16Run {
    await withCheckedContinuation { continuation in
      state.withLock { state in
        guard state.continuations[run.request] == nil else {
          fatalError("Async work request \(run.request) started twice.")
        }
        state.continuations[run.request] = continuation
      }
      startContinuation.yield(run)
    }
    return run
  }

  func finish(_ request: Int) {
    let continuation = state.withLock { $0.continuations.removeValue(forKey: request) }
    guard let continuation else {
      fatalError("Async work request \(request) finished before it started.")
    }
    continuation.resume()
  }

  nonisolated deinit {}
}

@MainActor
@Test func `ASYNC-16 concurrent work runs off actor and newest result commits on MainActor`()
  async throws
{
  let cogs = Cogs.forTesting()
  let request = ManualCog<Int>(0)
  let work = Async16ControlledWork()
  let forecast = AsyncCog<Async16Run>(
    default: Async16Run(request: -1, ranWithoutActorIsolation: false),
    name: "forecast"
  ) { c in
    let currentRequest = c[request]
    return .run { @concurrent in
      await work.run(
        Async16Run(
          request: currentRequest,
          ranWithoutActorIsolation: #isolation == nil
        )
      )
    }
  }
  let (phases, phaseContinuation) = AsyncStream.makeStream(
    of: CogMeta<Async16Run>.self
  )
  let token = cogs.run { c in
    let phase = c.meta[forecast]
    if case .success = phase {
      MainActor.preconditionIsolated("AsyncCog concurrent result publication")
    }
    phaseContinuation.yield(phase)
  }
  var phaseIterator = phases.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard await phaseIterator.next() != nil else {
    Issue.record("The phase stream ended before initial pending")
    return
  }
  #expect(
    await startIterator.next()
      == Async16Run(request: 0, ranWithoutActorIsolation: true)
  )

  cogs.commit("change request") { c in c[request] = 1 }
  guard await phaseIterator.next() != nil else {
    Issue.record("The phase stream ended before replacement pending")
    return
  }
  #expect(
    await startIterator.next()
      == Async16Run(request: 1, ranWithoutActorIsolation: true)
  )

  let staleChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: staleChecked)
  work.finish(0)
  try await staleChecked.wait()
  if case .pending(_, hasSucceeded: false) = cogs.meta.peek(forecast) {
  } else {
    Issue.record("The stale concurrent result escaped the generation check")
  }

  work.finish(1)
  guard let completed = await phaseIterator.next() else {
    Issue.record("The phase stream ended before success")
    return
  }
  if case .success(let run) = completed {
    #expect(run == Async16Run(request: 1, ranWithoutActorIsolation: true))
  } else {
    Issue.record("Expected the newest concurrent result to commit")
  }
  withExtendedLifetime(token) {}
}
