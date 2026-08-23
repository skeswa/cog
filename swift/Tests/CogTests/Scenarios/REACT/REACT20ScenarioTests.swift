#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func `REACT-20 export offers precede every reaction in one flush`() async {
  let sourceCog = Cog<Int>.Manual(0)
  var reactionValues: [Int] = []
  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in reactionValues.append(c[sourceCog]) }
    }
  ])
  var iterator = cogs.values(of: sourceCog).makeAsyncIterator()

  #expect(await iterator.next() == 0)

  cogs.turn("change exported source") { c in c[sourceCog] = 1 }

  #expect(reactionValues == [0, 1])
  #expect(await iterator.next() == 1)

  let turnEntries = cogs.debugHistory.entries.filter { $0.turn == 1 }
  let offerIndexes = turnEntries.indices.filter { turnEntries[$0].event == .offer }
  let effectIndexes = turnEntries.indices.filter { turnEntries[$0].event == .effect }

  #expect(offerIndexes.count == 1)
  #expect(effectIndexes.count == 1)
  #expect(offerIndexes[0] < effectIndexes[0])
}

#endif
