import Cog
import CogTesting
import Testing

@MainActor
@Test func `MECH-07 a gate already true at operate opens its scope immediately`() {
  let loggedIn = ManualCog<Bool>(true)
  let uploads = ManualCog<Int>(0)
  var seen: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.whenever(loggedIn) { s in
        s.run { c in seen.append(c[uploads]) }
      }
    }
  ])

  // The scope body ran during bootstrap: its registrations were live when
  // the factory returned, with no rise required.
  #expect(seen == [0])

  cogs.commit { c in c[uploads] = 1 }
  #expect(seen == [0, 1])
}

@MainActor
@Test func `MECH-08 a gate cycle tears the scope down and reopens it fresh`() async {
  let loggedIn = ManualCog<Bool>(false)
  let uploads = ManualCog<Int>(0)
  var bodyRuns = 0
  var seen: [Int] = []
  let (taskStarts, taskStartContinuation) = AsyncStream.makeStream(of: Void.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
  let (holds, holdContinuation) = AsyncStream.makeStream(of: Void.self)

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.whenever(loggedIn, name: "session") { s in
        bodyRuns += 1
        s.run { c in seen.append(c[uploads]) }
        s.task(name: "heartbeat") {
          // Deterministic cancellation observation: the start event proves
          // the body is running, and the held iterator yields nothing, so
          // `next()` returns nil exactly when the task is cancelled.
          taskStartContinuation.yield()
          var iterator = holds.makeAsyncIterator()
          _ = await iterator.next()
          cancellationContinuation.yield()
        }
      }
    }
  ])

  // A false gate registers nothing: the body has not run.
  #expect(bodyRuns == 0)
  #expect(seen.isEmpty)

  // The rise runs the body once; its registrations are live.
  cogs.commit(loggedIn, to: true)
  #expect(bodyRuns == 1)
  #expect(seen == [0])
  cogs.commit { c in c[uploads] = 1 }
  #expect(seen == [0, 1])

  // The task is running before the fall, so the cancellation it receives is
  // a definite later signal rather than a startup race.
  var startIterator = taskStarts.makeAsyncIterator()
  _ = await startIterator.next()

  // The fall ends everything the scope registered: the reaction never runs
  // again and the task receives cooperative cancellation.
  cogs.commit(loggedIn, to: false)
  var cancellationIterator = cancellations.makeAsyncIterator()
  _ = await cancellationIterator.next()
  cogs.commit { c in c[uploads] = 2 }
  #expect(seen == [0, 1])

  // The next rise runs the body again from scratch: fresh registrations that
  // observe current state, with nothing surviving the down-and-up cycle.
  cogs.commit(loggedIn, to: true)
  #expect(bodyRuns == 2)
  #expect(seen == [0, 1, 2])
  cogs.commit { c in c[uploads] = 3 }
  #expect(seen == [0, 1, 2, 3])
  _ = holdContinuation
}
