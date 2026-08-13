import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-09 a peek in an Observation scope stays unsubscribed`() {
  let cogs = Cogs.forTesting()
  let count = ManualCog<Int>(1)
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs.peek(count)
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == 1)

  cogs.commit { c in c[count] = 2 }

  #expect(cogs.peek(count) == 2)
  #expect(notices.withLock { $0 } == 0)
}
