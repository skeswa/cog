import Cog
import CogTesting
import Testing

@MainActor
@Test func `LIFE-11 releasing one key leaves the sibling key untouched`() async throws {
  // Lifetime is per exact state, and a box's states are per key: one key's
  // grace expiry releases that key alone. The watched sibling never recomputes
  // and keeps answering warm; the released key recreates from current values.
  let clock = TestClock()
  let workWatcherAlive = Cog<Bool>.Manual { true }
  let sources = CogBox<Int, String>.Manual { 1 }
  var runsByKey: [String: Int] = [:]
  let automatic = CogBox<Int, String> { c, key in
    runsByKey[key, default: 0] += 1
    return c[sources[key]] * 10
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.run { c in _ = c[automatic["home"]] }
  m.whenever(workWatcherAlive) { s in
    s.run { c in _ = c[automatic["work"]] }
  }
  #expect(runsByKey == ["home": 1, "work": 1])

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(workWatcherAlive, to: false)
  cogs.turn { c in c[sources["work"]] = 2 }
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(released.hasBeenAcknowledged)
  #expect(cogs.peek(automatic["home"]) == 10)
  #expect(runsByKey == ["home": 1, "work": 1])

  #expect(cogs.peek(automatic["work"]) == 20)
  #expect(runsByKey == ["home": 1, "work": 2])
}
