import CogTesting
import Observation
import Testing
import os

@testable import Cog

@MainActor
@Test func `ObservationBoundaryInfrastructure creates one boundary for one UI-read state`() {
  let cogs = Cogs.forTesting()
  let counts = ManualCogBox<Int, String>(0)
  let firstState = cogs.manualState(for: counts["first"])
  let secondState = cogs.manualState(for: counts["second"])

  #expect(firstState.observationBoundary == nil)
  #expect(secondState.observationBoundary == nil)

  let firstBoundary = firstState.accessObservationBoundary(in: cogs)

  #expect(firstState.observationBoundary === firstBoundary)
  #expect(firstState.accessObservationBoundary(in: cogs) === firstBoundary)
  #expect(secondState.observationBoundary == nil)
  #expect(cogs.observationStates.count == 1)
  #expect(cogs.observationStates[0] === firstState)
}

@MainActor
@Test func `ObservationBoundaryInfrastructure mutates only after a manual value changes`() {
  let cogs = Cogs.forTesting()
  let count = ManualCog<Int>(0)
  let state = cogs.manualState(for: count)
  let notices = OSAllocatedUnfairLock(initialState: 0)

  _ = withObservationTracking {
    state.accessObservationBoundary(in: cogs)
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  cogs.commit { c in c[count] = 0 }
  #expect(notices.withLock { $0 } == 0)

  cogs.commit { c in c[count] = 1 }
  #expect(notices.withLock { $0 } == 1)
}

@MainActor
@Test
func `ObservationBoundaryInfrastructure settles a derived boundary before change-only mutation`() {
  let cogs = Cogs.forTesting()
  let count = ManualCog<Int>(0)
  let isEven = Cog<Bool> { c in c[count].isMultiple(of: 2) }
  let state = cogs.derivedState(for: isEven)
  let notices = OSAllocatedUnfairLock(initialState: 0)

  withObservationTracking {
    state.accessObservationBoundary(in: cogs)
    #expect(state.settledValue(in: cogs))
  } onChange: {
    notices.withLock { $0 += 1 }
  }

  cogs.commit { c in c[count] = 2 }
  #expect(notices.withLock { $0 } == 0)
  #expect(state.cachedValue == true)

  cogs.commit { c in c[count] = 3 }
  #expect(notices.withLock { $0 } == 1)
  #expect(state.cachedValue == false)
}
