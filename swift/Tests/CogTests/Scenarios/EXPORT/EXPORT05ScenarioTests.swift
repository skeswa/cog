import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-05 subscribers own independent buffers and graph leases`() async {
  let sourceCog = ManualCog<Int>(0)
  var selectorRuns = 0
  let doubledCog = Cog<Int> { c in
    selectorRuns += 1
    return c[sourceCog] * 2
  }
  let cogs = Cogs.forTesting()
  var oldestIterator =
    cogs.values(of: doubledCog, buffering: .oldest(2)).makeAsyncIterator()

  do {
    var newestIterator =
      cogs.values(of: doubledCog, buffering: .newest(1)).makeAsyncIterator()

    #expect(await oldestIterator.next() == 0)
    #expect(await newestIterator.next() == 0)

    for value in 1...3 {
      cogs.commit(sourceCog, to: value)
    }

    #expect(await newestIterator.next() == 6)
    #expect(await oldestIterator.next() == 2)
    #expect(await oldestIterator.next() == 4)
  }

  cogs.commit(sourceCog, to: 4)
  #expect(await oldestIterator.next() == 8)
  #expect(selectorRuns == 5)
}
