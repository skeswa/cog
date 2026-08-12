import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-01 a changed cog invalidates a consumer that read it with get`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(1)
  let doubled = Cog<Int> { reader in reader.get(count) * 2 }
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs.get(doubled)
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == 2)

  cogs.commit { writer in writer[count] = 2 }

  #expect(notices.withLock { $0 } == 1)
  #expect(cogs.read(doubled) == 4)
}

@MainActor
@Test func `UI-02 a write to an unread cog leaves the consumer valid`() {
  let cogs = Cogtext.forTesting()
  let displayed = ManualCog<Int>(1)
  let unread = ManualCog<Int>(10)
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs.get(displayed)
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == 1)

  cogs.commit { writer in writer[unread] = 11 }

  #expect(notices.withLock { $0 } == 0)
  #expect(cogs.read(displayed) == 1)
  #expect(cogs.read(unread) == 11)
}
