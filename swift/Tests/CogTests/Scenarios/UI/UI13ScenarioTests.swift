import Cog
import CogTesting
import Observation
import Testing
import os

private nonisolated struct ObservedPair: Equatable, Sendable {
  let first: Int
  let second: Int
}

@MainActor
@Test func `UI-13 one commit never exposes a torn pair to an observed consumer`() {
  let cogs = Cogtext.forTesting()
  let first = ManualCog<Int>(0)
  let second = ManualCog<Int>(0)
  let renderedPairs = OSAllocatedUnfairLock(initialState: [ObservedPair]())

  let initial = withObservationTracking {
    ObservedPair(first: cogs.get(first), second: cogs.get(second))
  } onChange: {
    MainActor.assumeIsolated {
      let pair = ObservedPair(first: cogs.read(first), second: cogs.read(second))
      renderedPairs.withLock { $0.append(pair) }
    }
  }
  renderedPairs.withLock { $0.append(initial) }

  cogs.commit("change pair") { writer in
    writer[first] = 1
    writer[second] = 1
  }

  #expect(
    renderedPairs.withLock { $0 } == [
      ObservedPair(first: 0, second: 0),
      ObservedPair(first: 1, second: 1),
    ]
  )
}
