import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-03 writing one keyed value does not invalidate another keyed reader`() {
  let cogs = Cogs.forTesting()
  let weather = CogBox<String?, String>.Manual { nil }
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs[weather["10001"]]
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == nil)

  cogs.turn { c in c[weather["90210"]] = "sunny" }

  #expect(notices.withLock { $0 } == 0)
  #expect(cogs.peek(weather["10001"]) == nil)
  #expect(cogs.peek(weather["90210"]) == "sunny")
}
