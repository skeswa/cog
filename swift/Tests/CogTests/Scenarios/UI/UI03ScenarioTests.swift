import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-03 writing one keyed value does not invalidate another keyed reader`() {
  let cogs = Cogtext.forTesting()
  let weather = ManualCogBox<String?, String>(nil)
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs.get(weather["10001"])
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == nil)

  cogs.commit { writer in writer[weather["90210"]] = "sunny" }

  #expect(notices.withLock { $0 } == 0)
  #expect(cogs.read(weather["10001"]) == nil)
  #expect(cogs.read(weather["90210"]) == "sunny")
}
