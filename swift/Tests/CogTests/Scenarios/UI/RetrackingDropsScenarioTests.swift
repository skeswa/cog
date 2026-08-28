import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-16 a second tracking pass drops a previously read cog`() {
  // This is GRAPH-09 through Observation. Each SwiftUI render tracks only its
  // own reads, so a body stops invalidating when it stops reading a cog.
  let cogs = Cogs.forTesting()
  let a = Cog<Int>.Manual { 1 }
  let b = Cog<Int>.Manual { 10 }
  let firstRenderNotices = OSAllocatedUnfairLock(initialState: 0)
  let secondRenderNotices = OSAllocatedUnfairLock(initialState: 0)

  let firstRender = withObservationTracking {
    "\(cogs[a]):\(cogs[b])"
  } onChange: {
    firstRenderNotices.withLock { $0 += 1 }
  }
  #expect(firstRender == "1:10")

  // The re-render reads only B, so its registration must not inherit A.
  let secondRender = withObservationTracking {
    "\(cogs[b])"
  } onChange: {
    secondRenderNotices.withLock { $0 += 1 }
  }
  #expect(secondRender == "10")

  cogs.turn { c in c[a] = 2 }

  // The stale first registration fires because it read A, but the current
  // render stays quiet.
  #expect(firstRenderNotices.withLock { $0 } == 1)
  #expect(secondRenderNotices.withLock { $0 } == 0)

  cogs.turn { c in c[b] = 20 }

  #expect(secondRenderNotices.withLock { $0 } == 1)
}
