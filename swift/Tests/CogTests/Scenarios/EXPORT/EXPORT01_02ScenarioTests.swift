import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-01 EXPORT-02 values settle cold state then offer changes`() async {
  let sourceCog = Cog<Int>.Manual(2)
  var selectorRuns = 0
  let doubledCog = Cog<Int>(
    { c in
      selectorRuns += 1
      let source = c[sourceCog]
      return source * 2
    }, name: "doubled")
  let cogs = Cogs.forTesting()

  let values = cogs.values(of: doubledCog)
  var iterator = values.makeAsyncIterator()
  #expect(await iterator.next() == 4)
  #expect(selectorRuns == 1)

  cogs.turn(sourceCog, to: 3)
  #expect(await iterator.next() == 6)
  cogs.turn(sourceCog, to: 5)
  #expect(await iterator.next() == 10)
  #expect(selectorRuns == 3)
}
