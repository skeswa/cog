import Cog
import CogTesting
import Testing

// A reaction leases only what it reads itself. Everything further upstream is
// held by nothing but a dependency edge, and LIFE-09 is the promise that such
// an edge delays removal without ever becoming observation: it earns the
// upstream state no grace window of its own and cannot keep it resident once
// its consumer leaves.

@MainActor
@Test func `LIFE-09 an internal edge does not keep an upstream cog alive`() async throws {
  let clock = AutomaticLifetimeTestClock()
  let watcherAlive = Cog<Bool>.Manual { true }
  let source = Cog<Int>.Manual { 1 }
  var upstreamRuns = 0
  var downstreamRuns = 0
  let upstream = Cog<Int> { c in
    upstreamRuns += 1
    return c[source] + 1
  }
  let downstream = Cog<Int> { c in
    downstreamRuns += 1
    return c[upstream] * 2
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.whenever(watcherAlive) { s in
    s.run { c in _ = c[downstream] }
  }
  #expect(upstreamRuns == 1)
  #expect(downstreamRuns == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(watcherAlive, to: false)
  try await clock.waitForScheduledSleep()

  // One deadline, not two. The reaction leased only what it read, so the
  // upstream cog never had observation to lose and never earned a window.
  #expect(clock.activeSleeperCount == 1)
  clock.advance(by: .seconds(10))
  try await released.wait()

  // Both left together at that one deadline: an edge that had been deferring
  // the upstream cog's removal does not convert into a second grace window
  // when the consumer holding it goes away.
  #expect(clock.activeSleeperCount == 0)
  #expect(clock.maximumActiveSleeperCount == 1)

  // Reading recreates both from current values, not from what they cached
  // before the source changed.
  cogs.turn { c in c[source] = 10 }
  #expect(cogs.peek(downstream) == 22)
  #expect(upstreamRuns == 2)
  #expect(downstreamRuns == 2)
}

@MainActor
@Test func `LIFE-09 reading one released cog recreates only what it needs`() async throws {
  let clock = AutomaticLifetimeTestClock()
  let watcherAlive = Cog<Bool>.Manual { true }
  let source = Cog<Int>.Manual { 1 }
  var upstreamRuns = 0
  var downstreamRuns = 0
  let upstream = Cog<Int> { c in
    upstreamRuns += 1
    return c[source] + 1
  }
  let downstream = Cog<Int> { c in
    downstreamRuns += 1
    return c[upstream] * 2
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.whenever(watcherAlive) { s in
    s.run { c in _ = c[downstream] }
  }

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(watcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  cogs.turn { c in c[source] = 10 }

  // Reading the upstream value reference alone brings back that state and no
  // other: a released graph comes back a cog at a time, on demand.
  #expect(cogs.peek(upstream) == 11)
  #expect(upstreamRuns == 2)
  #expect(downstreamRuns == 1)

  #expect(cogs.peek(downstream) == 22)
  #expect(downstreamRuns == 2)
  // The upstream state the first peek recreated was still resident, so the
  // second read reused it instead of running the selector again.
  #expect(upstreamRuns == 2)
}
