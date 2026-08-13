import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-01 a changed cog invalidates a consumer that read it with subscript`() {
  let cogs = Cogs.forTesting()
  let count = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c[count] * 2 }
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs[doubled]
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == 2)

  cogs.commit { c in c[count] = 2 }

  #expect(notices.withLock { $0 } == 1)
  #expect(cogs.peek(doubled) == 4)
}

@MainActor
@Test func `UI-02 a write to an unread cog leaves the consumer valid`() {
  let cogs = Cogs.forTesting()
  let displayed = ManualCog<Int>(1)
  let unread = ManualCog<Int>(10)
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs[displayed]
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == 1)

  cogs.commit { c in c[unread] = 11 }

  #expect(notices.withLock { $0 } == 0)
  #expect(cogs.peek(displayed) == 1)
  #expect(cogs.peek(unread) == 11)
}
