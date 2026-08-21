#if DEBUG

import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `SEED-07 seed stays quiet until the next real turn`() {
  let cogs = Cogs.forTesting()
  let seeded = ManualCog<Int>(0, name: "seeded")
  let unrelated = ManualCog<Bool>(false, name: "unrelated")
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs[seeded]
  } onChange: {
    notices.withLock { $0 += 1 }
  }
  #expect(initial == 0)
  #expect(cogs.observationBoundaryCount == 1)
  #expect(cogs.hasObservationBoundary(for: seeded))

  cogs.seed(seeded, to: 1)

  #expect(cogs.peek(seeded) == 1)
  #expect(notices.withLock { $0 } == 0)
  #expect(cogs.debugHistory.entries.filter { $0.event == .notice }.isEmpty)

  cogs.turn("seed.followup") { c in c[unrelated] = true }

  #expect(notices.withLock { $0 } == 1)
  let notice = cogs.debugHistory.entries.filter { $0.event == .notice }.last
  #expect(notice?.name == "seeded")
}

#endif
