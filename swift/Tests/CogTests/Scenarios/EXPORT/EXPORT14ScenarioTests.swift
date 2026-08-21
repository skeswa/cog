import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-14 equal automatic recomputation offers no value`() async {
  let sourceCog = ManualCog<Int>(0)
  var selectorRuns = 0
  let bucketCog = Cog<Int> { c in
    selectorRuns += 1
    return c[sourceCog] / 10
  }
  let cogs = Cogs.forTesting()
  let values = cogs.values(of: bucketCog, buffering: .oldest(1))
  var iterator = values.makeAsyncIterator()

  #expect(await iterator.next() == 0)

  cogs.turn(sourceCog, to: 1)
  cogs.turn(sourceCog, to: 10)

  #expect(selectorRuns == 3)
  #expect(await iterator.next() == 1)
}
