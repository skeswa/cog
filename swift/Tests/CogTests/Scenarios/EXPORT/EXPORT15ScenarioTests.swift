import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-15 a live subscription holds state across every grace period`() async {
  let clock = TestClock()
  let sourceCog = Cog<Int>.Manual { 0 }
  var selectorRuns = 0
  let doubledCog = Cog<Int> { c in
    selectorRuns += 1
    return c[sourceCog] * 2
  }
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  var iterator = cogs.values(of: doubledCog).makeAsyncIterator()

  #expect(await iterator.next() == 0)
  #expect(clock.activeSleeperCount == 0)

  for value in 1...5 {
    clock.advance(by: .seconds(10))
    cogs.turn(sourceCog, to: value)
    #expect(await iterator.next() == value * 2)
    #expect(clock.activeSleeperCount == 0)
  }

  #expect(clock.maximumActiveSleeperCount == 0)
  #expect(selectorRuns == 6)
}
