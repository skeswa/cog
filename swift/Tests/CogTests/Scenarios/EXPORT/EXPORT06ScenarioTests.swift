import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-06 cancelling a reader releases its graph lease`() async throws {
  let clock = TestClock()
  let sourceCog = Cog<Int>.Manual(1)
  var selectorRuns = 0
  let doubledCog = Cog<Int> { c in
    selectorRuns += 1
    return c[sourceCog] * 2
  }
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  let (initialValues, initialContinuation) = AsyncStream.makeStream(of: Int?.self)
  var initialIterator = initialValues.makeAsyncIterator()

  let reader = Task { @MainActor in
    var iterator = cogs.values(of: doubledCog).makeAsyncIterator()
    initialContinuation.yield(await iterator.next())
    while await iterator.next() != nil {}
  }

  #expect(await initialIterator.next() == 2)
  #expect(selectorRuns == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  reader.cancel()
  await reader.value
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(cogs.peek(doubledCog) == 2)
  #expect(selectorRuns == 2)
}
