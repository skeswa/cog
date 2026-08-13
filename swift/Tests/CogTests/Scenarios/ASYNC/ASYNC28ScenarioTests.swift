import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
private final class Async28ControlledWork {
  let starts: AsyncStream<Void>

  private let startContinuation: AsyncStream<Void>.Continuation
  private var continuation: CheckedContinuation<Int, Never>?

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Void.self)
  }

  func run() async -> Int {
    startContinuation.yield()
    return await withCheckedContinuation { continuation = $0 }
  }

  func succeed(with value: Int) {
    guard let continuation else {
      fatalError("ASYNC-28 work completed before it started.")
    }
    self.continuation = nil
    continuation.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-28 an initial UI latest read does not reenter derived computation`()
  async throws
{
  let cogs = Cogtext.forTesting()
  let work = Async28ControlledWork()
  let forecast = AsyncCog<Int>(name: "forecast") { _ in
    .run { await work.run() }
  }
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs[forecast.latest]
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == nil)
  #expect(notices.withLock { $0 } == 0)
  #if DEBUG
  #expect(
    cogs.debugHistory.entries.filter {
      $0.event == .turn && $0.name == "forecast pending"
    }.count == 1
  )
  #endif

  var startIterator = work.starts.makeAsyncIterator()
  _ = await startIterator.next()

  let completed = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: completed)
  work.succeed(with: 42)
  try await completed.wait()

  #expect(notices.withLock { $0 } == 1)
  #expect(cogs[forecast.latest] == 42)
}
