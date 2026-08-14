import Cog
import CogTesting
import Testing

@MainActor
@Test func `MECH-09 lowering an outer gate cancels the nested scope too`() async {
  let sessionOpen = ManualCog<Bool>(true)
  let syncing = ManualCog<Bool>(true)
  let uploads = ManualCog<Int>(0)
  var outerSeen: [Int] = []
  var innerSeen: [Int] = []
  let (taskStarts, taskStartContinuation) = AsyncStream.makeStream(of: Void.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
  let (holds, holdContinuation) = AsyncStream.makeStream(of: Void.self)

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.whenever(sessionOpen, name: "session") { s in
        s.run { c in outerSeen.append(c[uploads]) }
        s.whenever(syncing, name: "sync") { inner in
          inner.run { c in innerSeen.append(c[uploads]) }
          inner.task(name: "pump") {
            taskStartContinuation.yield()
            var iterator = holds.makeAsyncIterator()
            _ = await iterator.next()
            cancellationContinuation.yield()
          }
        }
      }
    }
  ])

  // Both scopes opened at bootstrap: their gates already read true.
  #expect(outerSeen == [0])
  #expect(innerSeen == [0])

  // The inner task is running before the fall, so the cancellation below is
  // a definite later signal rather than a startup race.
  var startIterator = taskStarts.makeAsyncIterator()
  _ = await startIterator.next()

  // Lowering the outer gate alone tears down the inner scope's reaction and
  // task along with the outer scope's own registrations.
  cogs.commit(sessionOpen, to: false)
  var cancellationIterator = cancellations.makeAsyncIterator()
  _ = await cancellationIterator.next()

  cogs.commit { c in c[uploads] = 1 }
  #expect(outerSeen == [0])
  #expect(innerSeen == [0])
  _ = holdContinuation
}
