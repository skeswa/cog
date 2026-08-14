import Cog
import CogTesting
import Testing

/// Holds the last context reference off the MainActor so its release — and
/// therefore the context's isolated deinit — starts from another executor.
private actor ContextDropper {
  private var cogs: Cogs?

  init(cogs: consuming Cogs) {
    self.cogs = cogs
  }

  func drop() {
    self.preconditionIsolated()
    cogs = nil
  }
}

@MainActor
@Test func `MECH-10 background context release tears every mechanism scope down`() async throws {
  let source = ManualCog<Int>(0)
  let (taskStarts, taskStartContinuation) = AsyncStream.makeStream(of: Void.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
  let (holds, holdContinuation) = AsyncStream.makeStream(of: Void.self)
  let cleanup = MainActorCleanupAcknowledgement()

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in _ = c[source] }
      m.task(name: "heldUntilTeardown") {
        // The start event proves the body is running, and the held iterator
        // yields nothing, so `next()` returns nil exactly when teardown
        // cancels the owned task.
        taskStartContinuation.yield()
        var iterator = holds.makeAsyncIterator()
        _ = await iterator.next()
        cancellationContinuation.yield()
      }
    }
  ])
  cogs.acknowledgeDeinitCleanup(with: cleanup)
  #expect(!cleanup.hasBeenAcknowledged)
  weak let released: Cogs? = cogs

  // The owned task is running before the release, so the cancellation event
  // below is a definite later signal rather than a startup race.
  var startIterator = taskStarts.makeAsyncIterator()
  _ = await startIterator.next()

  let dropper = ContextDropper(cogs: consume cogs)
  let release = Task {
    await dropper.drop()
  }

  // Deinit cleanup reached the MainActor: scopes were cancelled before the
  // graph was released, so the registration is gone and the owned task has
  // received cooperative cancellation.
  try await cleanup.wait()
  #expect(cleanup.hasBeenAcknowledged)
  #expect(released == nil)

  var cancellationIterator = cancellations.makeAsyncIterator()
  _ = await cancellationIterator.next()
  await release.value
  _ = holdContinuation
}
