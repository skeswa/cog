import Cog
import CogTesting
import Testing

// `whileObserved(resetToInitial: true)` is the one lifetime that promises a
// source comes back at its starting value. With a stored starting value and a
// reference-type `Value`, that promise was unkeepable: the state came back as
// the very object it was released holding, carrying every mutation made to it.

/// A mutable reference-type value, the case this scenario exists for.
@MainActor
private final class Draft {
  var text: String = ""

  nonisolated deinit {}
}

// MARK: - LIFE-12

@MainActor
@Test func `LIFE-12 a reset source comes back as a fresh object, not the mutated one`() async throws
{
  let clock = AutomaticLifetimeTestClock()
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  var closureRuns = 0
  let draftCog = Cog<Draft>.Manual(
    {
      closureRuns += 1
      return Draft()
    },
    lifetime: .whileObserved(resetToInitial: true)
  )

  let beforeRelease = cogs.peek(draftCog)
  beforeRelease.text = "half a thought"
  #expect(closureRuns == 1)

  // Reading is transient demand: enough to renew one grace window, never
  // enough to keep the state.
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  clock.advance(by: .seconds(10))
  try await released.wait()

  let afterRelease = cogs.peek(draftCog)

  // The closure ran a second time, which is the whole mechanism: the reset
  // produces a value rather than handing back a retained one.
  #expect(closureRuns == 2)
  #expect(afterRelease !== beforeRelease)
  #expect(afterRelease.text == "")

  // And the object the caller still holds from before the release is not
  // secretly the graph's current value.
  beforeRelease.text = "mutated after release"
  #expect(cogs.peek(draftCog).text == "")
}
