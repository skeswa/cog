import CogTesting
import Testing

@testable import Cog

// MARK: - Mechanism task infrastructure
//
// These proofs green no scenario. They pin scope-owned task machinery: a task
// belongs to the scope that started it, receives cancellation when the scope
// ends, and a task requested after cancellation is already cancelled when
// `task` returns.

@MainActor
@Test func `MechanismTaskInfrastructure scope cancellation cancels owned tasks`() async {
  let (taskStarts, taskStartContinuation) = AsyncStream.makeStream(of: Void.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
  let (holds, holdContinuation) = AsyncStream.makeStream(of: Void.self)

  let scope = MechanismScope()
  scope.task(name: "held") {
    taskStartContinuation.yield()
    var iterator = holds.makeAsyncIterator()
    _ = await iterator.next()
    cancellationContinuation.yield()
  }

  // The task is running before cancellation, so the event below is a
  // definite later signal rather than a startup race.
  var startIterator = taskStarts.makeAsyncIterator()
  _ = await startIterator.next()

  scope.cancel()
  var cancellationIterator = cancellations.makeAsyncIterator()
  _ = await cancellationIterator.next()
  _ = holdContinuation
}

@MainActor
@Test func `MechanismTaskInfrastructure a task requested after cancellation is born cancelled`() {
  let scope = MechanismScope()
  scope.cancel()

  let task = scope.task(name: "late") {}
  #expect(task.isCancelled)
}
