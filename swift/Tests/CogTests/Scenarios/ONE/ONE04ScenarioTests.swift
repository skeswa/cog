import Cog
import CogTesting
import Testing

// MARK: - ONE-04

@MainActor
@Test func `ONE-04 a test gets a working context from the testing product alone`() {
  // No app bootstrap, no environment, no shared setup, no teardown: the whole
  // ceremony is one call, and the context that comes back is immediately
  // usable.
  let cogs = Cogs.forTesting()

  let retryLimit = ManualCog<Int>(3)

  #expect(cogs.peek(retryLimit) == 3)
}

@MainActor
@Test func `ONE-04 every request for a testing context gets a fresh one`() {
  // Two contexts, not one shared context handed out twice — which is what lets
  // two previews, or two tests running in parallel, each have their own world.
  let first = Cogs.forTesting()
  let second = Cogs.forTesting()

  #expect(first !== second)

  let retryLimit = ManualCog<Int>(3)

  #expect(first.peek(retryLimit) == 3)
  #expect(second.peek(retryLimit) == 3)
}

@MainActor
@Test func `ONE-04 a fresh context starts clean however many came before it`() {
  // The fiftieth context of a test run is as clean as the first. Nothing
  // accumulates in a process-global, so nothing has to be reset between tests.
  let declaration = ManualCog<Int>(3)

  for _ in 0..<50 {
    let cogs = Cogs.forTesting()
    #expect(cogs.peek(declaration) == 3)
  }
}
