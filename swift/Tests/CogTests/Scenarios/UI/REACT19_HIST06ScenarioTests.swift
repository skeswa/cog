#if DEBUG

import Cog
import CogTesting
import Observation
import Testing

@MainActor
@Test func `REACT-19 every changed UI boundary is noticed before any reaction runs`() {
  let cogs = Cogtext.forTesting()
  let first = ManualCog<Int>(0, name: "pair.first")
  let second = ManualCog<Int>(0, name: "pair.second")

  _ = withObservationTracking {
    (cogs.get(first), cogs.get(second))
  } onChange: {
  }

  let reaction = cogs.run { reader in
    _ = reader.get(first)
    _ = reader.get(second)
  }

  cogs.commit("change pair") { writer in
    writer[first] = 1
    writer[second] = 1
  }

  let turnEntries = cogs.debugHistory.entries.filter { $0.turn == 1 }
  let noticeIndexes = turnEntries.indices.filter { turnEntries[$0].event == .notice }
  let effectIndexes = turnEntries.indices.filter { turnEntries[$0].event == .effect }

  #expect(noticeIndexes.count == 2)
  #expect(effectIndexes.count == 1)
  #expect(noticeIndexes.allSatisfy { $0 < effectIndexes[0] })
  _ = reaction
}

@MainActor
@Test func `HIST-06 history names each changed keyed UI notice`() {
  let cogs = Cogtext.forTesting()
  let weather = ManualCogBox<String?, String>(nil, name: "weather")
  let zip = "90210"

  _ = withObservationTracking {
    cogs.get(weather[zip])
  } onChange: {
  }

  cogs.commit("update weather") { writer in
    writer[weather[zip]] = "sunny"
  }

  let notices = cogs.debugHistory.entries.filter { $0.event == .notice }
  #expect(notices.count == 1)
  #expect(notices[0].name == "weather[90210]")
  #expect(notices[0].turn == 1)
}

#endif
