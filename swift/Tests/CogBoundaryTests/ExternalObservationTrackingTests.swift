#if canImport(UIKit)

import Cog
import CogTesting
import Observation
import Testing

@available(iOS 26.0, *)
@MainActor
@Observable
private final class ExternalObservationModel {
  var tracked = 0
  var unrelated = 0
}

@available(iOS 26.0, *)
@MainActor
@Test(.timeLimit(.minutes(1)))
func `EXPORT-08 tracked properties publish the newest value after every boundary`() async {
  let model = ExternalObservationModel()
  var selectorRuns = 0
  let doubledCog = Cog<Int> { c in
    selectorRuns += 1
    return c.track(model, \.tracked) * 2
  }
  let cogs = Cogs.forTesting()
  var values = cogs.values(of: doubledCog).makeAsyncIterator()

  #expect(await values.next() == 0)
  #expect(selectorRuns == 1)

  for value in 1...3 {
    model.tracked = value
    await Task.yield()

    #expect(await values.next() == value * 2)
    #expect(cogs.peek(doubledCog) == value * 2)
    #expect(selectorRuns == value + 1)
  }
}

@available(iOS 26.0, *)
@MainActor
@Test(.timeLimit(.minutes(1)))
func `EXPORT-10 tracking one property ignores sibling mutations`() async {
  let model = ExternalObservationModel()
  var selectorRuns = 0
  let doubledCog = Cog<Int> { c in
    selectorRuns += 1
    return c.track(model, \.tracked) * 2
  }
  let cogs = Cogs.forTesting()
  var values = cogs.values(of: doubledCog).makeAsyncIterator()

  #expect(await values.next() == 0)
  #expect(selectorRuns == 1)

  model.unrelated = 1
  await Task.yield()
  model.tracked = 1
  await Task.yield()

  #expect(await values.next() == 2)
  #expect(selectorRuns == 2)
}

#endif
