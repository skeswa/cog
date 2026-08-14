import Cog
import CogTesting
import Testing

extension Cogs {
  fileprivate func setFromReaction(_ source: ManualCog<Int>, to value: Int) {
    commit("reaction.writeback") { c in c[source] = value }
  }
}

// Reaction behavior is proved through the public registration, read, and turn
// APIs. Tokens stay alive for the duration of each test so later cancellation
// semantics cannot turn these wake-up tests into lifetime tests by accident.

@MainActor
@Test func `REACT-01 run performs its initial tracking run immediately`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c[source])
  }

  #expect(seen == [1])
  _ = token
}

@MainActor
@Test func `REACT-02 REACT-07 a change wakes the reaction before the commit returns`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c[source])
  }

  cogs.commit { c in c[source] = 2 }

  // One assertion carries both claims: the reaction reran because its
  // dependency changed (REACT-02), and it had already completed when the line
  // after the commit ran — no await, polling, or callback (REACT-07).
  #expect(seen == [1, 2])
  _ = token
}

@MainActor
@Test func `REACT-03 an unrelated turn leaves the reaction quiet`() {
  let cogs = Cogs.forTesting()
  let observed = ManualCog<Int>(1)
  let unrelated = ManualCog<Int>(10)
  var runs = 0

  let token = cogs.run { c in
    _ = c[observed]
    runs += 1
  }

  cogs.commit { c in c[unrelated] = 11 }

  #expect(runs == 1)
  _ = token
}

@MainActor
@Test func `REACT-04 dependencies settle before the reaction body starts`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  var events: [String] = []
  let doubled = Cog<Int> { c in
    let value = c[source] * 2
    events.append("derive:\(value)")
    return value
  }

  let token = cogs.run { c in
    events.append("react:begin")
    events.append("react:value:\(c[doubled])")
  }

  events.removeAll()
  cogs.commit { c in c[source] = 2 }

  #expect(events == ["derive:4", "react:begin", "react:value:4"])
  _ = token
}

@MainActor
@Test func `REACT-05 changed reactions run in registration order`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var order: [Int] = []

  let first = cogs.run { c in
    _ = c[source]
    order.append(1)
  }
  let second = cogs.run { c in
    _ = c[source]
    order.append(2)
  }
  let third = cogs.run { c in
    _ = c[source]
    order.append(3)
  }

  order.removeAll()
  cogs.commit { c in c[source] = 1 }

  #expect(order == [1, 2, 3])
  _ = (first, second, third)
}

@MainActor
@Test func `REACT-05 cancellation does not reorder the surviving reactions`() {
  // A registration made after another's cancellation still runs last: slot
  // reuse must not let a newcomer inherit a cancelled reaction's place in the
  // registration order.
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var order: [Int] = []

  let first = cogs.run { c in
    _ = c[source]
    order.append(1)
  }
  let second = cogs.run { c in
    _ = c[source]
    order.append(2)
  }
  let third = cogs.run { c in
    _ = c[source]
    order.append(3)
  }

  second.cancel()
  let fourth = cogs.run { c in
    _ = c[source]
    order.append(4)
  }

  order.removeAll()
  cogs.commit { c in c[source] = 1 }

  #expect(order == [1, 3, 4])
  _ = (first, third, fourth)
}

@MainActor
@Test func `REACT-06 every run replaces the reaction dependency set`() {
  let cogs = Cogs.forTesting()
  let useX = ManualCog<Bool>(true)
  let x = ManualCog<Int>(1)
  let y = ManualCog<Int>(10)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c[useX] ? c[x] : c[y])
  }

  cogs.commit { c in c[y] = 11 }
  #expect(seen == [1])

  cogs.commit { c in c[useX] = false }
  #expect(seen == [1, 11])

  cogs.commit { c in c[y] = 12 }
  #expect(seen == [1, 11, 12])

  cogs.commit { c in c[x] = 2 }
  #expect(seen == [1, 11, 12])
  _ = token
}

@MainActor
@Test func `REACT-23 flush-time registrations join the reaction queue tail`() {
  let cogs = Cogs.forTesting()
  let trigger = ManualCog<Int>(0)
  let writeback = ManualCog<Int>(0)
  var events: [String] = []
  var spawned: [ReactionToken] = []

  let first = cogs.run { c in
    guard c[trigger] == 1 else { return }

    events.append("first:begin")
    spawned.append(
      cogs.run { c in
        _ = c[trigger]
        events.append("third:initial")
        cogs.commit("third.writeback") { c in c[writeback] = 1 }
      }
    )
    spawned.append(
      cogs.run { c in
        _ = c[trigger]
        events.append("fourth:initial")
        cogs.commit("fourth.writeback") { c in c[writeback] = 2 }
      }
    )
    events.append("first:end")
  }

  let second = cogs.run { c in
    guard c[trigger] == 1 else { return }
    events.append("second")
  }

  let writebackObserver = cogs.run { c in
    let value = c[writeback]
    guard value > 0 else { return }
    events.append("writeback:\(value)")
  }

  cogs.commit { c in c[trigger] = 1 }

  #expect(
    events == [
      "first:begin",
      "first:end",
      "second",
      "third:initial",
      "fourth:initial",
      "writeback:1",
      "writeback:2",
    ]
  )
  #expect(spawned.count == 2)
  _ = (first, second, writebackObserver)
}

@MainActor
@Test func `REACT-15 REACT-16 reaction write-back chains drain settled and FIFO`() {
  // The first hop is REACT-15: `second` wakes exactly once, after `first`'s
  // whole body ran, seeing middle already settled — the reaction's op landed
  // as a brand-new turn after the flush, never a change to the turn being
  // flushed and never a synchronous nested flush (that would run `third`
  // before `side`). The rest of the chain is REACT-16: each queued turn runs
  // first-in first-out, fully settled.
  let cogs = Cogs.forTesting()
  let trigger = ManualCog<Int>(0)
  let middle = ManualCog<Int>(0)
  let side = ManualCog<Int>(0)
  let leaf = ManualCog<Int>(0)
  var events: [String] = []
  var reactionDepth = 0
  var maximumDepth = 0

  func record(_ name: String) {
    reactionDepth += 1
    maximumDepth = max(maximumDepth, reactionDepth)
    defer { reactionDepth -= 1 }
    events.append(
      "\(name):\(cogs.peek(trigger))/\(cogs.peek(middle))/\(cogs.peek(side))/\(cogs.peek(leaf))"
    )
  }

  let first = cogs.run { c in
    guard c[trigger] == 1 else { return }
    record("first")
    cogs.setFromReaction(middle, to: 1)
    cogs.setFromReaction(side, to: 1)
  }

  let second = cogs.run { c in
    guard c[middle] == 1 else { return }
    record("second")
    cogs.setFromReaction(leaf, to: 1)
  }

  let sideObserver = cogs.run { c in
    guard c[side] == 1 else { return }
    record("side")
  }

  let third = cogs.run { c in
    guard c[leaf] == 1 else { return }
    record("third")
  }

  cogs.commit { c in c[trigger] = 1 }

  #expect(
    events == [
      "first:1/0/0/0",
      "second:1/1/0/0",
      "side:1/1/1/0",
      "third:1/1/1/1",
    ]
  )
  #expect(maximumDepth == 1)
  _ = (first, second, sideObserver, third)
}

@MainActor
@Test func `REACT-16 a watch sees every queued write-back value with true old-new pairs`() {
  // The same FIFO chain observed through `watch` instead of `run`: each queued
  // turn is its own delivery, no intermediate value is skipped, and every old
  // half really is the previous turn's value.
  let cogs = Cogs.forTesting()
  let trigger = ManualCog<Int>(0)
  let count = ManualCog<Int>(0)
  var deliveries: [String] = []

  let starter = cogs.run { c in
    guard c[trigger] == 1 else { return }
    cogs.setFromReaction(count, to: 1)
  }
  let escalator = cogs.run { c in
    guard c[count] == 1 else { return }
    cogs.setFromReaction(count, to: 2)
  }
  let token = cogs.watch(count, initial: .skip, name: "watch.chain") { old, new in
    deliveries.append("\(old)->\(new)")
  }

  cogs.commit { c in c[trigger] = 1 }

  #expect(deliveries == ["0->1", "1->2"])
  _ = (starter, escalator, token)
}
