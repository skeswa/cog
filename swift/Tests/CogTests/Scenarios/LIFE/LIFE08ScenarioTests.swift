import Cog
import CogTesting
import Testing

@MainActor
@Test func `LIFE-08 a first UI read pins an automatic cog for the context lifetime`() async throws {
  let clock = AutomaticLifetimeTestClock()
  let watcherAlive = ManualCog<Bool>(true)
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

  cogs.turn(watcherAlive, to: false)
  try await clock.waitForScheduledSleep()

  #expect(cogs[automatic] == 10)
  #expect(selectorRuns == 1)
  #expect(clock.activeSleeperCount == 0)

  clock.advance(by: .seconds(10))

  #expect(cogs.peek(automatic) == 10)
  #expect(selectorRuns == 1)
}
