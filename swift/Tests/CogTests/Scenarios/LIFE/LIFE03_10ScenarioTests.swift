import Cog
import CogTesting
import Testing

@MainActor
@Test func `LIFE-03 the same value reference recreates from current state after release`()
  async throws
{
  // This walk contains the retired LIFE-02 whole: the automatic cog uses the
  // default `whileObserved` lifetime, its last watcher leaves, injected grace
  // elapses, and the release acknowledgement fires. LIFE-03's own claim is
  // the recreation: the same value reference comes back computed fresh —
  // `c.curr` is nil again — from the state the source has now.
  let clock = TestClock()
  let watcherAlive = Cog<Bool>.Manual { true }
  let source = Cog<Int>.Manual { 1 }
  var previousValues: [Int?] = []
  let automatic = Cog<Int> { c in
    previousValues.append(c.curr)
    return c[source]
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.whenever(watcherAlive) { s in
    s.run { c in _ = c[automatic] }
  }
  #expect(previousValues == [nil])

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(watcherAlive, to: false)
  cogs.turn { c in c[source] = 2 }
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(cogs.peek(automatic) == 2)
  #expect(previousValues == [nil, nil])
}

@MainActor
@Test func `LIFE-10 one-shot automatic peek renews grace then releases and recreates`()
  async throws
{
  let clock = TestClock()
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  let source = Cog<Int>.Manual { 1 }
  var previousValues: [Int?] = []
  let automatic = Cog<Int> { c in
    previousValues.append(c.curr)
    return c[source]
  }

  #expect(cogs.peek(automatic) == 1)
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)

  clock.advance(by: .seconds(4))
  for _ in 0..<32 {
    #expect(cogs.peek(automatic) == 1)
    try await clock.waitForScheduledSleep()
    #expect(clock.activeSleeperCount == 1)
  }
  #expect(previousValues == [nil])
  #expect(clock.maximumActiveSleeperCount == 1)

  clock.advance(by: .seconds(6))
  #expect(clock.activeSleeperCount == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  clock.advance(by: .seconds(4))
  try await released.wait()
  #expect(clock.activeSleeperCount == 0)

  cogs.turn { c in c[source] = 2 }
  #expect(cogs.peek(automatic) == 2)
  #expect(previousValues == [nil, nil])
}
