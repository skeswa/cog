#if DEBUG

import Cog
import CogTesting
import Observation
import Testing

@MainActor
@Test func `HIST-06 history names each changed keyed UI notice`() {
  let (cogs, m) = probedContext()
  let weather = CogBox<String?, String>.Manual({ nil }, name: "weather")
  let zip = "90210"

  _ = withObservationTracking {
    cogs[weather[zip]]
  } onChange: {
  }

  cogs.turn("update weather") { c in
    c[weather[zip]] = "sunny"
  }

  let notices = cogs.debugHistory.entries.filter { $0.event == .notice }
  #expect(notices.count == 1)
  #expect(notices[0].name == "weather[90210]")
  #expect(notices[0].turn == 1)
}

#endif
