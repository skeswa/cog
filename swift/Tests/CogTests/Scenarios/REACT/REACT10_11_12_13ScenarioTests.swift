import Cog
import CogTesting
import Testing

// Token lifecycle proved through the public registration and turn APIs. Every
// test holds its tokens alive across the commits it asserts on, so that when
// dropping the last copy also cancels, these stay proofs about `cancel()`
// rather than turning into lifetime tests by accident.

@MainActor
@Test func `REACT-10 a cancelled token stops the reaction for good`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c.get(source))
  }

  #expect(seen == [1])

  token.cancel()

  cogs.commit { w in w[source] = 2 }
  cogs.commit { w in w[source] = 3 }

  #expect(seen == [1])
  // The turns really happened; the reaction simply was not there for them.
  #expect(cogs.read(source) == 3)

  _ = token
}

@MainActor
@Test func `REACT-10 cancelling during a flush stops runs that flush had queued`() {
  let cogs = Cogtext.forTesting()
  let trigger = ManualCog<Int>(0)
  var events: [String] = []
  var queued: ReactionToken?
  var spawned: [ReactionToken] = []

  let canceller = cogs.run { c in
    guard c.get(trigger) == 1 else { return }
    events.append("canceller")

    // Already scanned into this flush's queue as a changed run, at an index the
    // drain has not reached yet.
    queued?.cancel()

    // Registered inside the flush, so its first run joins the queue's tail, and
    // then cancelled before the drain arrives there.
    let stillborn = cogs.run { inner in
      _ = inner.get(trigger)
      events.append("stillborn")
    }
    stillborn.cancel()
    spawned.append(stillborn)
  }

  queued = cogs.run { c in
    _ = c.get(trigger)
    events.append("queued")
  }

  let survivor = cogs.run { c in
    _ = c.get(trigger)
    events.append("survivor")
  }

  events.removeAll()
  cogs.commit { w in w[trigger] = 1 }

  // Neither cancelled run happened, and the flush carried on around them.
  #expect(events == ["canceller", "survivor"])
  #expect(spawned.count == 1)

  _ = (canceller, queued, survivor, spawned)
}

@MainActor
@Test func `REACT-11 cancelling the same token twice is harmless`() {
  let cogs = Cogtext.forTesting()
  let cancelled = ManualCog<Int>(1)
  let watched = ManualCog<Int>(1)
  var seen: [Int] = []
  var survivorRuns = 0

  let token = cogs.run { c in
    seen.append(c.get(cancelled))
  }
  let survivor = cogs.run { c in
    _ = c.get(watched)
    survivorRuns += 1
  }

  token.cancel()
  token.cancel()
  token.cancel()

  cogs.commit { w in w[cancelled] = 2 }
  cogs.commit { w in w[watched] = 2 }

  #expect(seen == [1])
  // The repeats took nothing else with them: a cancellation that removed by
  // position rather than by identity would have taken this one.
  #expect(survivorRuns == 2)

  _ = (token, survivor)
}

@MainActor
@Test func `REACT-12 dropping the last token copy cancels the reaction`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  // Two copies of one registration, released one at a time. Optionals rather
  // than a scope, so the drop happens on a line this test names instead of
  // wherever the compiler decides the last use was.
  var held: ReactionToken? = cogs.run { c in
    seen.append(c.get(source))
  }
  var copy: ReactionToken? = held

  #expect(seen == [1])

  copy = nil

  cogs.commit { w in w[source] = 2 }

  // Not the last copy, so the registration is untouched.
  #expect(seen == [1, 2])

  held = nil

  cogs.commit { w in w[source] = 3 }

  // Now it was, and the reaction stopped — synchronously, with no await and no
  // poll, because the token was released on the actor the graph runs on.
  #expect(seen == [1, 2])
  #expect(cogs.read(source) == 3)

  _ = (held, copy)
}

@MainActor
@Test func `REACT-13 token copies name one registration`() {
  let cogs = Cogtext.forTesting()
  let aliased = ManualCog<Int>(1)
  let collected = ManualCog<Int>(1)
  var aliasedSeen: [Int] = []
  var collectedSeen: [Int] = []

  let aliasedToken = cogs.run { c in
    aliasedSeen.append(c.get(aliased))
  }
  let collectedToken = cogs.run { c in
    collectedSeen.append(c.get(collected))
  }

  let alias = aliasedToken
  var owned: [ReactionToken] = []
  owned.append(collectedToken)

  #expect(alias === aliasedToken)
  #expect(owned[0] === collectedToken)

  alias.cancel()
  owned[0].cancel()

  cogs.commit { w in
    w[aliased] = 2
    w[collected] = 2
  }

  #expect(aliasedSeen == [1])
  #expect(collectedSeen == [1])

  // Cancelling through the copy that did not do it is the same no-op a repeat
  // cancel is, because both copies name the one registration.
  aliasedToken.cancel()
  collectedToken.cancel()

  cogs.commit { w in
    w[aliased] = 3
    w[collected] = 3
  }

  #expect(aliasedSeen == [1])
  #expect(collectedSeen == [1])

  _ = (aliasedToken, collectedToken, alias, owned)
}
