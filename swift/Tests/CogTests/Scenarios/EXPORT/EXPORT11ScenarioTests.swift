import Cog
import CogTesting
import Observation
import Testing

@MainActor
@Observable
private final class Export11Model {
  var tracked = 0
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func `EXPORT-11 legacy tracking acknowledges re-arm before the next mutation`() async throws {
  let model = Export11Model()
  var selectorRuns = 0
  let doubledCog = Cog<Int> { c in
    selectorRuns += 1
    return c.track(model, \.tracked) * 2
  }
  let cogs = Cogs.forTesting(externalObservationTracking: .legacy)
  var values = cogs.values(of: doubledCog).makeAsyncIterator()

  #expect(await values.next() == 0)
  #expect(selectorRuns == 1)

  let firstRearm = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextExternalObservationRearm(with: firstRearm)
  model.tracked = 1
  try await firstRearm.wait()

  #expect(await values.next() == 2)
  #expect(cogs.peek(doubledCog) == 2)
  #expect(selectorRuns == 2)

  let secondRearm = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextExternalObservationRearm(with: secondRearm)
  model.tracked = 2
  try await secondRearm.wait()

  #expect(await values.next() == 4)
  #expect(cogs.peek(doubledCog) == 4)
  #expect(selectorRuns == 3)
}
