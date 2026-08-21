import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `UI-16 a second tracking pass drops a previously read cog`() {
  // The Observation analog of GRAPH-09, which SwiftUI relies on every render:
  // each render tracks only what that render read, so a body that stops
  // reading a cog stops being invalidated by it.
  let cogs = Cogs.forTesting()
  let a = ManualCog<Int>(1)
  let b = ManualCog<Int>(10)
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

  // The stale first registration fires — it really read A — but the current
  // render stays quiet.
  #expect(firstRenderNotices.withLock { $0 } == 1)
  #expect(secondRenderNotices.withLock { $0 } == 0)

  cogs.turn { c in c[b] = 20 }

  #expect(secondRenderNotices.withLock { $0 } == 1)
}
