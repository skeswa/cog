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
@Test func `UI-13 one turn never exposes a torn pair to an observed consumer`() {
  let cogs = Cogs.forTesting()
  let first = ManualCog<Int>(0)
  let second = ManualCog<Int>(0)
  let renderedPairs = OSAllocatedUnfairLock(initialState: [ObservedPair]())

  let initial = withObservationTracking {
    ObservedPair(first: cogs[first], second: cogs[second])
  } onChange: {
    MainActor.assumeIsolated {
      let pair = ObservedPair(first: cogs.peek(first), second: cogs.peek(second))
      renderedPairs.withLock { $0.append(pair) }
    }
  }
  renderedPairs.withLock { $0.append(initial) }

  cogs.turn("change pair") { c in
    c[first] = 1
    c[second] = 1
  }

  #expect(
    renderedPairs.withLock { $0 } == [
      ObservedPair(first: 0, second: 0),
      ObservedPair(first: 1, second: 1),
    ]
  )
}
