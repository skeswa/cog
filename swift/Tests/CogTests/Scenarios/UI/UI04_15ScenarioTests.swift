import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-04 an equal derived recomputation sends no Observation notice`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(1)
  var selectorRuns = 0
  let isOdd = Cog<Bool> { reader in
    selectorRuns += 1
    return !reader.get(count).isMultiple(of: 2)
  }
  let notices = OSAllocatedUnfairLock(initialState: 0)

  #expect(
    withObservationTracking {
      cogs.get(isOdd)
    } onChange: {
      notices.withLock { $0 += 1 }
    }
  )
  #expect(selectorRuns == 1)

  cogs.commit { writer in writer[count] = 3 }

  #expect(selectorRuns == 2)
  #expect(cogs.read(isOdd))
  #expect(notices.withLock { $0 } == 0)
}

@MainActor
@Test func `UI-15 an equal manual write sends no Observation notice`() {
  let cogs = Cogtext.forTesting()
  let status = ManualCog<String>("ready")
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs.get(status)
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == "ready")

  cogs.commit { writer in writer[status] = "ready" }

  #expect(cogs.read(status) == "ready")
  #expect(notices.withLock { $0 } == 0)
}
