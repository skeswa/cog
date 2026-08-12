import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-09 a one-shot read in an Observation scope stays unsubscribed`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(1)
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs.read(count)
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == 1)

  cogs.commit { writer in writer[count] = 2 }

  #expect(cogs.read(count) == 2)
  #expect(notices.withLock { $0 } == 0)
}
