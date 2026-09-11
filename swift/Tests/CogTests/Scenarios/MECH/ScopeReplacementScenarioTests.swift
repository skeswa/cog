import Cog
import CogTesting
import Testing

// Replacement while the work is still active: what the old lifetime loses, what
// the new one gets, and what ordering both observe.

/// A session lifetime, minted where sign-in creates it.
private struct Epoch: Equatable {
  let value: Int
}

@MainActor
@Test func `MECH-22 replacing an identity stops the old work and installs the new once`()
  async
{
  let epoch = Cog<Epoch?>.Manual { Epoch(value: 1) }
  let uploads = Cog<Int>.Manual { 0 }
  // A derived condition that stays true across the replacement, which is
  // exactly what a Bool gate cannot express.
  let isSignedIn = Cog<Bool> { c in c[epoch] != nil }

  var installs: [Int] = []
  var seen: [String] = []
  let (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Int.self)
  let (heartbeats, heartbeatContinuation) = AsyncStream.makeStream(of: Int.self)
  var currentHeartbeat: AsyncStream<Void>.Continuation?

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        // A witness that the derived condition never falls: if it did, this
        // reaction would record the gap.
        seen.append("gate:\(c[isSignedIn])")
      }
      m.scope(epoch, name: "session") { session, s in
        installs.append(session.value)
        s.watch(uploads, initial: .skip, name: "sync") { _, count in
          seen.append("sync\(session.value):\(count)")
        }
        // Cancelling any iterator finishes its entire AsyncStream. Each
        // task lifetime therefore needs its own stream, even on reopening.
        let (holds, holdContinuation) = AsyncStream.makeStream(of: Void.self)
        currentHeartbeat = holdContinuation
        s.task(name: "heartbeat") {
          defer { withExtendedLifetime(holdContinuation) {} }
          startContinuation.yield(session.value)
          var iterator = holds.makeAsyncIterator()
          while await iterator.next() != nil {
            heartbeatContinuation.yield(session.value)
          }
          #expect(Task.isCancelled)
          cancellationContinuation.yield(session.value)
        }
      }
    }
  ])
  #expect(installs == [1])
  #expect(seen == ["gate:true"])

  var startIterator = starts.makeAsyncIterator()
  #expect(await startIterator.next() == 1)

  cogs.turn(uploads, to: 1)
  #expect(seen == ["gate:true", "sync1:1"])

  // A → B in one turn. The condition never falls, so nothing about this is a
  // close-and-reopen cycle; it is a replacement.
  cogs.turn(epoch, to: Epoch(value: 2))
  #expect(installs == [1, 2])

  // The old session's task received cancellation.
  var cancellationIterator = cancellations.makeAsyncIterator()
  #expect(await cancellationIterator.next() == 1)
  #expect(await startIterator.next() == 2)

  // Starting is insufficient: a replacement consuming its predecessor's
  // finished stream also announces a start. Prove it can still receive work.
  guard case .enqueued? = currentHeartbeat?.yield() else {
    Issue.record("The replacement heartbeat stream ended before its scope retired")
    return
  }
  var heartbeatIterator = heartbeats.makeAsyncIterator()
  #expect(await heartbeatIterator.next() == 2)

  // The old watch is gone and the new one is installed exactly once: a single
  // entry, not two.
  cogs.turn(uploads, to: 2)
  #expect(seen == ["gate:true", "sync1:1", "sync2:2"])
  cogs.turn(epoch, to: nil)
  #expect(await cancellationIterator.next() == 2)
}

@MainActor
@Test func `MECH-23 mixed Boolean and identity scopes retire with their ancestor`() async {
  let epoch = Cog<Epoch?>.Manual { Epoch(value: 1) }
  let syncing = Cog<Bool>.Manual { true }
  let uploads = Cog<Int>.Manual { 0 }
  var outerSeen: [Int] = []
  var innerSeen: [Int] = []
  var deepSeen: [Int] = []
  let (starts, startContinuation) = AsyncStream.makeStream(of: Void.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      // Identity outside, Boolean inside, identity again inside that. Names
      // compose the whole way down.
      m.scope(epoch, name: "session") { _, s in
        s.run { c in outerSeen.append(c[uploads]) }
        s.scope(syncing, name: "sync") { inner in
          inner.run { c in innerSeen.append(c[uploads]) }
          inner.scope(epoch, name: "generation") { _, deep in
            deep.run { c in deepSeen.append(c[uploads]) }
            deep.task(name: "pump") {
              // This wait belongs to this task alone, never to a later scope opening.
              let (holds, holdContinuation) = AsyncStream.makeStream(of: Void.self)
              defer { withExtendedLifetime(holdContinuation) {} }
              startContinuation.yield()
              var iterator = holds.makeAsyncIterator()
              _ = await iterator.next()
              #expect(Task.isCancelled)
              cancellationContinuation.yield()
            }
          }
        }
      }
    }
  ])
  #expect(outerSeen == [0])
  #expect(innerSeen == [0])
  #expect(deepSeen == [0])

  var startIterator = starts.makeAsyncIterator()
  _ = await startIterator.next()

  // Retiring the outermost identity retires the whole subtree, two levels down.
  cogs.turn(epoch, to: nil)
  var cancellationIterator = cancellations.makeAsyncIterator()
  _ = await cancellationIterator.next()

  cogs.turn(uploads, to: 1)
  #expect(outerSeen == [0])
  #expect(innerSeen == [0])
  #expect(deepSeen == [0])

  // Repeated teardown is safe: lowering the inner Boolean after its ancestor is
  // already gone changes nothing and traps nothing.
  cogs.turn(syncing, to: false)
  cogs.turn(uploads, to: 2)
  #expect(deepSeen == [0])
}

@MainActor
@Test func `MECH-24 one turn may replace an identity and wake the old child's reaction`() {
  // The selector watch registered before the child's reaction, so replacement
  // happens first in flush order. The old child's queued run must then be
  // skipped rather than running against state its lifetime no longer owns.
  let epoch = Cog<Epoch?>.Manual { Epoch(value: 1) }
  let uploads = Cog<Int>.Manual { 0 }
  var seen: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(epoch, name: "session") { session, s in
        s.run { c in seen.append("\(session.value):\(c[uploads])") }
      }
    }
  ])
  #expect(seen == ["1:0"])

  cogs.turn("replace the session while its reaction is waking") { c in
    c[uploads] = 1
    c[epoch] = Epoch(value: 2)
  }

  // Session 1's reaction was queued by the `uploads` change and then skipped;
  // only session 2's fresh registration ran, and it saw the settled value.
  #expect(seen == ["1:0", "2:1"])

  cogs.turn(uploads, to: 2)
  #expect(seen == ["1:0", "2:1", "2:2"])
}

/// Where a late completion publishes, and the receipt it must carry.
///
/// The op reads the current epoch and validates the receipt *inside* the writer
/// body. That placement is the point: a retired scope never reaches the body, so
/// the check never runs against a lifetime that no longer exists, and a live
/// scope still has to prove its work is current.
@MainActor private let _publishedResultCog = Cog<String>.Manual { "none" }

extension CogOps {
  /// Publishes one session's result if that session is still the current one.
  fileprivate func publishSessionResult(_ result: String, receipt: Epoch) {
    turn { c in
      guard c[_currentEpochCog] == receipt else { return }
      c[_publishedResultCog] = result
    }
  }
}

/// The session epoch both the scope and the acceptance check read.
@MainActor private let _currentEpochCog = Cog<Epoch?>.Manual { Epoch(value: 1) }

@MainActor
@Test func `MECH-24 a replacement's first registration joins the reaction tail`() {
  // Replacement happens inside the selector's own reaction run, so the new
  // child registers during an active flush. Its initial run must join that
  // flush's tail — behind reactions already queued and behind reactions
  // registered earlier in the same flush — rather than reentering the selector
  // that opened it.
  let epoch = Cog<Epoch?>.Manual { Epoch(value: 1) }
  let trigger = Cog<Int>.Manual { 0 }
  var order: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      // Registered before the selector, so this reaction is already queued by
      // the time the selector replaces the identity.
      m.run { c in
        guard c[trigger] == 1 else { return }
        order.append("earlier")
      }
      m.scope(epoch, name: "session") { session, s in
        order.append("open\(session.value)")
        s.run { _ in order.append("child\(session.value)") }
      }
      // Registered after the selector, so this reaction is behind it in the
      // same queue.
      m.run { c in
        guard c[trigger] == 1 else { return }
        order.append("later")
      }
    }
  ])
  #expect(order == ["open1", "child1"])

  order.removeAll()
  cogs.turn("replace while waking siblings") { c in
    c[trigger] = 1
    c[epoch] = Epoch(value: 2)
  }

  // The selector body ran in its registration position, opening the new child
  // there. The child's own initial run did not happen inside that body — the
  // sibling registered after the selector still ran first, because the new
  // registration joined the tail.
  #expect(order == ["earlier", "open2", "later", "child2"])
}

@MainActor
@Test func `MECH-28 cancellation-resistant work cannot block or outlive its replacement`()
  async
{
  var installs: [Int] = []
  let (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  let (finishes, finishContinuation) = AsyncStream.makeStream(of: Int.self)
  let gate = ScopeTestGate()

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(_currentEpochCog, name: "session") { session, s in
        installs.append(session.value)
        s.task(name: "resistant") { [weak s] in
          startContinuation.yield(session.value)
          // Deliberately ignores cancellation: it waits for the test alone,
          // exactly as a request already sent to a server would.
          await gate.wait(session.value)
          await MainActor.run {
            s?.publishSessionResult("session\(session.value)", receipt: session)
          }
          finishContinuation.yield(session.value)
        }
      }
    }
  ])
  var startIterator = starts.makeAsyncIterator()
  #expect(await startIterator.next() == 1)

  // Replacement does not wait for the old task: session 2 starts while session
  // 1's work is still suspended.
  cogs.turn(_currentEpochCog, to: Epoch(value: 2))
  #expect(installs == [1, 2])
  #expect(await startIterator.next() == 2)

  // Now let session 1 finish. Its controller is retired, so its op never
  // reaches a writer body at all.
  gate.release(1)
  var finishIterator = finishes.makeAsyncIterator()
  #expect(await finishIterator.next() == 1)
  #expect(cogs.peek(_publishedResultCog) == "none")

  // Session 2's identical completion publishes, proving the assertion above
  // measures retirement rather than a broken test path.
  gate.release(2)
  #expect(await finishIterator.next() == 2)
  #expect(cogs.peek(_publishedResultCog) == "session2")
}
