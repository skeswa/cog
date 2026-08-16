import Cog
import CogTesting
import Testing

// Sources are the one kind of state Cog cannot recompute, so releasing one
// always means losing what was written to it. That is why the default is app
// lifetime (LIFE-01) and why letting a source go is an explicit declaration
// that says what coming back looks like (LIFE-05).

@MainActor
@Test func `LIFE-01 an unwatched source keeps its value`() async throws {
  let clock = DerivedLifetimeTestClock()
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  let count = ManualCog<Int>(0)

  cogs.commit { c in c[count] = 7 }
  #expect(cogs.peek(count) == 7)

  // App lifetime does not schedule a deadline at all, so there is nothing for
  // any amount of elapsed time to expire.
  #expect(clock.maximumActiveSleeperCount == 0)
  clock.advance(by: .seconds(600))

  #expect(cogs.peek(count) == 7)
  #expect(clock.maximumActiveSleeperCount == 0)
}

@MainActor
@Test func `LIFE-01 a source outlives the derived cog that was reading it`() async throws {
  let clock = DerivedLifetimeTestClock()
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  let count = ManualCog<Int>(0)
  var selectorRuns = 0
  let doubled = Cog<Int> { c in
    selectorRuns += 1
    return c[count] * 2
  }

  cogs.commit { c in c[count] = 7 }
  #expect(cogs.peek(doubled) == 14)

  // The derived cog is unobserved, so it leaves at its deadline. The source it
  // read is app-lifetime and is not swept up in that release.
  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(cogs.peek(count) == 7)
  // Recreating the derived cog reads the surviving source rather than a
  // starting value.
  #expect(cogs.peek(doubled) == 14)
  #expect(selectorRuns == 2)
}

@MainActor
@Test func `LIFE-05 an opted-in source starts over after release`() async throws {
  let clock = DerivedLifetimeTestClock()
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  let draft = ManualCog<String>("", lifetime: .whileObserved(resetToInitial: true))

  cogs.commit { c in c[draft] = "half a thought" }
  #expect(cogs.peek(draft) == "half a thought")

  // Writing and reading are transient demand: enough to renew one grace
  // window, never enough to keep the value.
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  clock.advance(by: .seconds(10))
  try await released.wait()

  // The declaration said what coming back means, so this is the promise being
  // kept rather than state quietly disappearing.
  #expect(cogs.peek(draft) == "")
}

@MainActor
@Test func `LIFE-05 an opted-in source survives while a reaction reads it`() async throws {
  let clock = DerivedLifetimeTestClock()
  let watcherAlive = ManualCog<Bool>(true)
  let draft = ManualCog<String>("", lifetime: .whileObserved(resetToInitial: true))
  var observed: [String] = []

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.whenever(watcherAlive) { s in
    s.run { c in observed.append(c[draft]) }
  }
  #expect(observed == [""])

  cogs.commit { c in c[draft] = "half a thought" }
  #expect(observed == ["", "half a thought"])

  // The reaction leases the source, so neither the write nor the passage of
  // time opens a grace window.
  #expect(clock.maximumActiveSleeperCount == 0)
  clock.advance(by: .seconds(600))
  #expect(cogs.peek(draft) == "half a thought")

  // The watcher leaves. Now the source is ephemeral again.
  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  cogs.commit(watcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(cogs.peek(draft) == "")
}
