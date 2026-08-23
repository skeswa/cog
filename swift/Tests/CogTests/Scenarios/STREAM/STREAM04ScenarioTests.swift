import Cog
import CogTesting
import Testing

@MainActor
@Test func `STREAM-04 release cancels a live stream and rejects its late element`() async throws {
  let clock = TestClock()
  let (cogs, m) = probedContext(clock: clock, whileObservedGrace: .seconds(10))
  let watcherAlive = Cog<Bool>.Manual(true)
  let work = DependencyStreamWork()
  let readingsCog = Cog<Int>.Async(.latest, default: -1, name: "readings") { _ in
    work.makeWork(dependency: 0)
  }
  var observedStatuses: [CogStatus<Int>] = []
  m.whenever(watcherAlive, name: "readings.scope") { scope in
    scope.run { c in
      let readings = c.status[readingsCog]
      observedStatuses.append(readings)
    }
  }
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  let initialStart = await startIterator.next()
  #expect(initialStart == DependencyStreamStart(generation: 0, dependency: 0))
  #expect(observedStatuses.map(\.kind) == [.pending])

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(watcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()
  #expect(await cancellationIterator.next() == 0)

  let lateChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: lateChecked)
  await work.send(99, to: 0)
  try await lateChecked.wait()
  #expect(observedStatuses.map(\.value) == [-1])
  #if DEBUG
  let successTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "readings success"
  }
  #expect(successTurns.isEmpty)
  #endif

  let fresh = cogs.status.peek(readingsCog)
  #expect(fresh.kind == .pending)
  #expect(fresh.value == -1)
  #expect(!fresh.hasSucceeded)
  let freshStart = await startIterator.next()
  #expect(freshStart == DependencyStreamStart(generation: 1, dependency: 0))

  let ended = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: ended)
  await work.send(nil, to: 1)
  try await ended.wait()
}
