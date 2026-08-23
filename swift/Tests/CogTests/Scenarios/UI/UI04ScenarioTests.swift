import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-04 an equal automatic recomputation sends no Observation notice`() {
  let cogs = Cogs.forTesting()
  let count = Cog<Int>.Manual(1)
  var selectorRuns = 0
  let isOdd = Cog<Bool> { c in
    selectorRuns += 1
    return !c[count].isMultiple(of: 2)
  }
  let notices = OSAllocatedUnfairLock(initialState: 0)

  #expect(
    withObservationTracking {
      cogs[isOdd]
    } onChange: {
      notices.withLock { $0 += 1 }
    }
  )
  #expect(selectorRuns == 1)

  cogs.turn { c in c[count] = 3 }

  #expect(selectorRuns == 2)
  #expect(cogs.peek(isOdd))
  #expect(notices.withLock { $0 } == 0)
}

@MainActor
@Test func `UI-04 an equal manual write sends no Observation notice`() {
  let cogs = Cogs.forTesting()
  let status = Cog<String>.Manual("ready")
  let notices = OSAllocatedUnfairLock(initialState: 0)

  let initial = withObservationTracking {
    cogs[status]
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  #expect(initial == "ready")

  cogs.turn { c in c[status] = "ready" }

  #expect(cogs.peek(status) == "ready")
  #expect(notices.withLock { $0 } == 0)
}
