import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-05 subscribers own independent buffers and graph leases`() async {
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
  var oldestIterator =
    cogs.values(of: doubledCog, buffering: .oldest(2)).makeAsyncIterator()

  do {
    var newestIterator =
      cogs.values(of: doubledCog, buffering: .newest(1)).makeAsyncIterator()

    #expect(await oldestIterator.next() == 0)
    #expect(await newestIterator.next() == 0)

    for value in 1...3 {
      cogs.turn(sourceCog, to: value)
    }

    #expect(await newestIterator.next() == 6)
    #expect(await oldestIterator.next() == 2)
    #expect(await oldestIterator.next() == 4)
  }

  // The newest subscriber is gone, and "neither releases the lease of the
  // other" must survive grace, not just the next instant: the survivor's lease
  // means no release deadline is ever scheduled, so advancing far past the
  // grace window changes nothing. A zero maximum sleeper count also rules out
  // a transient deadline that was scheduled and cancelled in between.
  clock.advance(by: .seconds(60))
  cogs.turn(sourceCog, to: 4)
  #expect(await oldestIterator.next() == 8)
  clock.advance(by: .seconds(60))
  #expect(clock.activeSleeperCount == 0)
  #expect(clock.maximumActiveSleeperCount == 0)
  #expect(selectorRuns == 5)
}
