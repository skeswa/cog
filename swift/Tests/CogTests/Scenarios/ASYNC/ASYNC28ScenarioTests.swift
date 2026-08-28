import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `ASYNC-28 an initial UI value read does not reenter automatic computation`()
  async throws
{
  let cogs = Cogs.forTesting()
  let work = ControlledWork<Int?>()
  let forecast = Cog<Int?>.Async(default: nil, name: "forecast") { _ in
    work.makeWork()
  }
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs[forecast]
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
  #expect(await startIterator.next() == 0)

  let completed = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: completed)
  work.succeed(0, with: 42)
  try await completed.wait()

  #expect(notices.withLock { $0 } == 1)
  #expect(cogs[forecast] == 42)
}
