import Cog
import CogTesting
import Testing

// Both scenarios here assert a negative — nothing was released — so both use
// the injected clock's sleeper count as the proof. A state with a pending
// release has exactly one sleeping deadline; a state that is leased, or whose
// deadline was cancelled, has none. Counting sleepers therefore says what
// "never released" means without polling, sleeping, or reaching into storage.

@MainActor
@Test func `LIFE-04 a watcher returning within grace cancels the pending release`() async throws {
  let clock = AutomaticLifetimeTestClock()
  let watcherAlive = Cog<Bool>.Manual(true)
  var selectorRuns = 0
  let automatic = Cog<Int> { _ in
    selectorRuns += 1
    return 10
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.whenever(watcherAlive) { s in
    s.run { c in _ = c[automatic] }
  }
  #expect(selectorRuns == 1)
  #expect(clock.activeSleeperCount == 0)

  // The watcher leaves. Grace begins, but the state is still here.
  cogs.turn(watcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)
  clock.advance(by: .seconds(6))
  #expect(clock.activeSleeperCount == 1)

  // The watcher comes back with time to spare. The deadline goes away with it.
  cogs.turn(watcherAlive, to: true)
  #expect(clock.activeSleeperCount == 0)

  // Well past the original deadline, and past a whole second grace window: a
  // cancelled deadline stays cancelled rather than firing late.
  clock.advance(by: .seconds(30))
  #expect(clock.activeSleeperCount == 0)

  // The returning watcher found the same live state, so nothing recomputed —
  // neither its own tracking run nor this read.
  #expect(cogs.peek(automatic) == 10)
  #expect(selectorRuns == 1)
}

@MainActor
@Test func `LIFE-07 a registered reaction leases the cogs it reads`() async throws {
  let clock = AutomaticLifetimeTestClock()
  let source = Cog<Int>.Manual(1)
  var leasedRuns = 0
  var unleasedRuns = 0
  let leased = Cog<Int> { c in
    leasedRuns += 1
    return c[source]
  }
  let unleased = Cog<Int> { c in
    unleasedRuns += 1
    return c[source]
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.run { c in _ = c[leased] }
  #expect(leasedRuns == 1)
  // A lease is not a grace window: a leased state schedules no deadline at all.
  #expect(clock.activeSleeperCount == 0)

  // Its unleased twin gets only the transient demand of a one-shot peek, which
  // is what makes the comparison below a real one rather than a tautology.
  #expect(cogs.peek(unleased) == 1)
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  clock.advance(by: .seconds(10))
  try await released.wait()
  #expect(clock.activeSleeperCount == 0)
  #expect(clock.maximumActiveSleeperCount == 1)

  // The leased cog is still here and still warm.
  #expect(cogs.peek(leased) == 1)
  #expect(leasedRuns == 1)
  // Its twin left and comes back only by recomputing.
  #expect(cogs.peek(unleased) == 1)
  #expect(unleasedRuns == 2)
}

@MainActor
@Test func `LIFE-07 a leased cog survives its own retracking`() async throws {
  let clock = AutomaticLifetimeTestClock()
  let source = Cog<Int>.Manual(1)
  var selectorRuns = 0
  let automatic = Cog<Int> { c in
    selectorRuns += 1
    return c[source] * 2
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  var observed: [Int] = []
  m.run { c in observed.append(c[automatic]) }
  #expect(observed == [2])

  // Waking the reaction retracks its dependencies. Retracking releases and
  // reacquires leases, so this is exactly where a lease could be dropped for
  // an instant and a grace window started by mistake.
  cogs.turn { c in c[source] = 5 }
  #expect(observed == [2, 10])
  #expect(clock.activeSleeperCount == 0)
  #expect(clock.maximumActiveSleeperCount == 0)

  clock.advance(by: .seconds(60))
  #expect(clock.activeSleeperCount == 0)
  #expect(cogs.peek(automatic) == 10)
  #expect(selectorRuns == 2)
}
