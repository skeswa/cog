#if DEBUG

import Cog
import CogTesting
import Observation
import Testing

@MainActor
@Test func `REACT-19 every changed UI boundary is noticed before any reaction runs`() {
  let (cogs, m) = Cogs.forTestingWithController()
  let first = Cog<Int>.Manual({ 0 }, name: "pair.first")
  let second = Cog<Int>.Manual({ 0 }, name: "pair.second")

  _ = withObservationTracking {
    (cogs[first], cogs[second])
  } onChange: {
  }

  m.run { c in
    _ = c[first]
    _ = c[second]
  }

  cogs.turn("change pair") { c in
    c[first] = 1
    c[second] = 1
  }

  let turnEntries = cogs.debugHistory.entries.filter { $0.turn == 1 }
  let noticeIndexes = turnEntries.indices.filter { turnEntries[$0].event == .notice }
  let effectIndexes = turnEntries.indices.filter { turnEntries[$0].event == .effect }

  #expect(noticeIndexes.count == 2)
  #expect(effectIndexes.count == 1)
  #expect(noticeIndexes.allSatisfy { $0 < effectIndexes[0] })
}

#endif
