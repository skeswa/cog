import Cog
import CogTesting
import Testing

private actor EffectGroupDropper {
  private var group: EffectGroup?

  init(group: consuming EffectGroup) {
    self.group = group
  }

  func drop() {
    self.preconditionIsolated()
    group = nil
  }
}

@MainActor
@Test func `GROUP-09 background group release acknowledges MainActor cleanup`() async throws {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []
  let group = EffectGroup()
  group.add(cogs.run { reader in seen.append(reader.get(source)) })

  let (startedEvents, startedContinuation) = AsyncStream.makeStream(
    of: Void.self,
    bufferingPolicy: .bufferingNewest(1)
  )
  let (releaseEvents, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
  let task = group.task(name: "group.backgroundCleanup") {
    startedContinuation.yield()
    var releaseIterator = releaseEvents.makeAsyncIterator()
    guard await releaseIterator.next() != nil else {
      throw CancellationError()
    }
  }
  var startedIterator = startedEvents.makeAsyncIterator()
  #expect(await startedIterator.next() != nil)

  let cleanup = MainActorCleanupAcknowledgement()
  group.acknowledgeDeinitCleanup(with: cleanup)
  let dropper = EffectGroupDropper(group: consume group)

  let release = Task {
    await dropper.drop()
  }
  try await cleanup.wait()

  #expect(cleanup.hasBeenAcknowledged)
  #expect(task.isCancelled)
  await #expect(throws: CancellationError.self) {
    try await task.value
  }
  cogs.commit { writer in writer[source] = 1 }
  #expect(seen == [0])
  #expect(cogs.read(source) == 1)

  await release.value
  withExtendedLifetime(releaseContinuation) {}
}
