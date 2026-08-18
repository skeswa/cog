import Cog
import CogTesting
import Observation
import Testing

@MainActor
@Observable
private final class Export13Model {
  var tracked = 0
  var other = 0
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func `EXPORT-13 legacy closure tracking publishes after every acknowledged re-arm`() async throws {
  let model = Export13Model()
  var selectorRuns = 0
  let combinedCog = Cog<Int> { c in
    selectorRuns += 1
    return c.track(model) { external in
      external.tracked * 10 + external.other
    }
  }
  let cogs = Cogs.forTesting(externalObservationTracking: .legacy)
  var values = cogs.values(of: combinedCog).makeAsyncIterator()

  #expect(await values.next() == 0)
  #expect(selectorRuns == 1)

  let firstRearm = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextExternalObservationRearm(with: firstRearm)
  model.tracked = 1
  try await firstRearm.wait()

  #expect(await values.next() == 10)
  #expect(cogs.peek(combinedCog) == 10)
  #expect(selectorRuns == 2)

  let secondRearm = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextExternalObservationRearm(with: secondRearm)
  model.other = 2
  try await secondRearm.wait()

  #expect(await values.next() == 12)
  #expect(cogs.peek(combinedCog) == 12)
  #expect(selectorRuns == 3)
}
