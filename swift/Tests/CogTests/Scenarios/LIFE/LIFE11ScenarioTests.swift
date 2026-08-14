import Cog
import CogTesting
import Testing

@MainActor
@Test func `LIFE-11 releasing one key leaves the sibling key untouched`() async throws {
  // Lifetime is per exact state, and a box's states are per key: one key's
  // grace expiry releases that key alone. The watched sibling never recomputes
  // and keeps answering warm; the released key recreates from current values.
  let clock = DerivedLifetimeTestClock()
  let workWatcherAlive = ManualCog<Bool>(true)
  let sources = ManualCogBox<Int, String>(1)
  var runsByKey: [String: Int] = [:]
  let derived = CogBox<Int, String> { c, key in
    runsByKey[key, default: 0] += 1
    return c[sources[key]] * 10
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.run { c in _ = c[derived["home"]] }
  m.whenever(workWatcherAlive) { s in
    s.run { c in _ = c[derived["work"]] }
  }
  #expect(runsByKey == ["home": 1, "work": 1])

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  cogs.commit(workWatcherAlive, to: false)
  cogs.commit { c in c[sources["work"]] = 2 }
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(released.hasBeenAcknowledged)
  #expect(cogs.peek(derived["home"]) == 10)
  #expect(runsByKey == ["home": 1, "work": 1])

  #expect(cogs.peek(derived["work"]) == 20)
  #expect(runsByKey == ["home": 1, "work": 2])
}
