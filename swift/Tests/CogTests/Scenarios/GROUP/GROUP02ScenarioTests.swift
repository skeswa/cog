import Cog
import Testing

@MainActor
@Test func `GROUP-02 cancellation propagates to owned and later tasks`() async {
  let group = EffectGroup()
  let copy = group
  let (startedEvents, startedContinuation) = AsyncStream.makeStream(
    of: Void.self,
    bufferingPolicy: .bufferingNewest(1)
  )
  let (releaseEvents, releaseContinuation) = AsyncStream.makeStream(of: Void.self)

  let ownedTask = group.task(name: "group.owned") {
    startedContinuation.yield()
    var releaseIterator = releaseEvents.makeAsyncIterator()
    guard await releaseIterator.next() != nil else {
      throw CancellationError()
    }
  }
  var startedIterator = startedEvents.makeAsyncIterator()
  #expect(await startedIterator.next() != nil)

  copy.cancel()
  #expect(ownedTask.isCancelled)
  await #expect(throws: CancellationError.self) {
    try await ownedTask.value
  }

  var firstRan = false
  let firstLaterTask = group.task(name: "group.afterCancel.first") {
    firstRan = true
  }
  #expect(firstLaterTask.isCancelled)
  await #expect(throws: CancellationError.self) {
    try await firstLaterTask.value
  }

  var secondRan = false
  let secondLaterTask = copy.task(name: "group.afterCancel.second") {
    secondRan = true
  }
  #expect(secondLaterTask.isCancelled)
  await #expect(throws: CancellationError.self) {
    try await secondLaterTask.value
  }

  #expect(!firstRan)
  #expect(!secondRan)
  withExtendedLifetime(releaseContinuation) {}
}
