import Cog
import CogTesting
import Testing

@MainActor
@Test func `MECH-07 a gate already true at operate opens its scope immediately`() {
  let loggedIn = Cog<Bool>.Manual { true }
  let uploads = Cog<Int>.Manual { 0 }
  var seen: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(loggedIn) { s in
        s.run { c in seen.append(c[uploads]) }
      }
    }
  ])

  // The scope body ran during assembly: its registrations were live when
  // the factory returned, with no rise required.
  #expect(seen == [0])

  cogs.turn { c in c[uploads] = 1 }
  #expect(seen == [0, 1])
}

@MainActor
@Test func `MECH-08 a gate cycle tears the scope down and reopens it fresh`() async {
  let loggedIn = Cog<Bool>.Manual { false }
  let uploads = Cog<Int>.Manual { 0 }
  var bodyRuns = 0
  var seen: [Int] = []
  let (taskStarts, taskStartContinuation) = AsyncStream.makeStream(of: Int.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Int.self)
  let (heartbeats, heartbeatContinuation) = AsyncStream.makeStream(of: Int.self)
  var currentHeartbeat: AsyncStream<Void>.Continuation?

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(loggedIn, name: "session") { s in
        bodyRuns += 1
        let generation = bodyRuns
        s.run { c in seen.append(c[uploads]) }
        // Cancelling any iterator finishes its entire AsyncStream. Each
        // task lifetime therefore needs its own stream, even on reopening.
        let (holds, holdContinuation) = AsyncStream.makeStream(of: Void.self)
        currentHeartbeat = holdContinuation
        s.task(name: "heartbeat") {
          defer { withExtendedLifetime(holdContinuation) {} }
          taskStartContinuation.yield(generation)
          var iterator = holds.makeAsyncIterator()
          while await iterator.next() != nil {
            heartbeatContinuation.yield(generation)
          }
          #expect(Task.isCancelled)
          cancellationContinuation.yield(generation)
        }
      }
    }
  ])

  // A false gate registers nothing: the body has not run.
  #expect(bodyRuns == 0)
  #expect(seen.isEmpty)

  // The rise runs the body once; its registrations are live.
  cogs.turn(loggedIn, to: true)
  #expect(bodyRuns == 1)
  #expect(seen == [0])
  cogs.turn { c in c[uploads] = 1 }
  #expect(seen == [0, 1])

  // The task is running before the fall, so the cancellation it receives is
  // a definite later signal rather than a startup race.
  var startIterator = taskStarts.makeAsyncIterator()
  #expect(await startIterator.next() == 1)

  // The fall ends everything the scope registered: the reaction never runs
  // again and the task receives cooperative cancellation.
  cogs.turn(loggedIn, to: false)
  var cancellationIterator = cancellations.makeAsyncIterator()
  #expect(await cancellationIterator.next() == 1)
  cogs.turn { c in c[uploads] = 2 }
  #expect(seen == [0, 1])

  // The next rise runs the body again from scratch: fresh registrations that
  // observe current state, with nothing surviving the down-and-up cycle.
  cogs.turn(loggedIn, to: true)
  #expect(bodyRuns == 2)
  #expect(await startIterator.next() == 2)

  // Reopening must provide live work, not merely rerun the registration body.
  guard case .enqueued? = currentHeartbeat?.yield() else {
    Issue.record("The reopened heartbeat stream ended before its scope retired")
    return
  }
  var heartbeatIterator = heartbeats.makeAsyncIterator()
  #expect(await heartbeatIterator.next() == 2)
  #expect(seen == [0, 1, 2])
  cogs.turn { c in c[uploads] = 3 }
  #expect(seen == [0, 1, 2, 3])
  cogs.turn(loggedIn, to: false)
  #expect(await cancellationIterator.next() == 2)
}
