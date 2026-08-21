import Observation
import Testing

@testable import Cog

@MainActor
@Observable
private final class LegacyObservationModel {
  var tracked = 0
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func `LegacyObservationTrackingInfrastructure reads after the setter and then re-arms`() async {
  let model = LegacyObservationModel()
  var published: [Int] = []
  var rearmCount = 0
  var rearmCountsAtPublication: [Int] = []
  let (changes, continuation) = AsyncStream.makeStream(of: Int.self)
  var iterator = changes.makeAsyncIterator()
  let shim = CogLegacyObservationShim(
    read: { model.tracked },
    didChange: { value in
      rearmCountsAtPublication.append(rearmCount)
      published.append(value)
      continuation.yield(value)
    },
    didRearm: { rearmCount += 1 }
  )

  shim.start()
  model.tracked = 1
  model.tracked = 2

  #expect(published.isEmpty)
  #expect(await iterator.next() == 2)
  #expect(published == [2])
  #expect(rearmCount == 1)
  #expect(rearmCountsAtPublication == [1])
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func `LegacyObservationTrackingInfrastructure re-arm observes the next mutation`() async {
  let model = LegacyObservationModel()
  var rearmCount = 0
  let (changes, continuation) = AsyncStream.makeStream(of: Int.self)
  var iterator = changes.makeAsyncIterator()
  let shim = CogLegacyObservationShim(
    read: { model.tracked },
    didChange: { continuation.yield($0) },
    didRearm: { rearmCount += 1 }
  )

  shim.start()
  model.tracked = 1
  #expect(await iterator.next() == 1)
  #expect(rearmCount == 1)

  model.tracked = 2
  #expect(await iterator.next() == 2)
  #expect(rearmCount == 2)
}
