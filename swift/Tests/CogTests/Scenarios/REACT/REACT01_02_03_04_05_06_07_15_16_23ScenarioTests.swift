import Cog
import CogTesting
import Testing

extension CogOperating {
  fileprivate func setFromReaction(_ source: ManualCog<Int>, to value: Int) {
    commit("reaction.writeback") { c in c[source] = value }
  }
}

// Reaction behavior is proved through the public mechanism registration,
// read, and turn APIs. Each test bootstraps one probe mechanism and registers
// through its controller, which the runtime's scope keeps alive for the whole
// isolated-context lifetime.

@MainActor
@Test func `REACT-01 run performs its initial tracking run immediately`() {
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  _ = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        seen.append(c[source])
      }
    }
  ])

  #expect(seen == [1])
}

@MainActor
@Test func `REACT-02 REACT-07 a change wakes the reaction before the commit returns`() {
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        seen.append(c[source])
      }
    }
  ])

  cogs.commit { c in c[source] = 2 }

  // One assertion carries both claims: the reaction reran because its
  // dependency changed (REACT-02), and it had already completed when the line
  // after the commit ran — no await, polling, or callback (REACT-07).
  #expect(seen == [1, 2])
}

@MainActor
@Test func `REACT-03 an unrelated turn leaves the reaction quiet`() {
  let observed = ManualCog<Int>(1)
  let unrelated = ManualCog<Int>(10)
  var runs = 0

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        _ = c[observed]
        runs += 1
      }
    }
  ])

  cogs.commit { c in c[unrelated] = 11 }

  #expect(runs == 1)
}

@MainActor
@Test func `REACT-04 dependencies settle before the reaction body starts`() {
  let source = ManualCog<Int>(1)
  var events: [String] = []
  let doubled = Cog<Int> { c in
    let value = c[source] * 2
    events.append("derive:\(value)")
    return value
  }

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        events.append("react:begin")
        events.append("react:value:\(c[doubled])")
      }
    }
  ])

  events.removeAll()
  cogs.commit { c in c[source] = 2 }

  #expect(events == ["derive:4", "react:begin", "react:value:4"])
}

@MainActor
@Test func `REACT-05 changed reactions run in registration order`() {
  let source = ManualCog<Int>(0)
  var order: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        _ = c[source]
        order.append(1)
      }
      m.run { c in
        _ = c[source]
        order.append(2)
      }
      m.run { c in
        _ = c[source]
        order.append(3)
      }
    }
  ])

  order.removeAll()
  cogs.commit { c in c[source] = 1 }

  #expect(order == [1, 2, 3])
}

@MainActor
@Test func `REACT-05 scope teardown does not reorder the surviving reactions`() {
  // A registration made after another's teardown still runs last: slot reuse
  // must not let a newcomer inherit a departed reaction's place in the
  // registration order. The second reaction lives in a `whenever` scope whose
  // gate starts true, so its registration slot is real; lowering the gate
  // removes it.
  let secondAlive = ManualCog<Bool>(true)
  let source = ManualCog<Int>(0)
  var order: [Int] = []
  var m: MechanismController!

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { controller in
      m = controller
      m.run { c in
        _ = c[source]
        order.append(1)
      }
      m.whenever(secondAlive) { s in
        s.run { c in
          _ = c[source]
          order.append(2)
        }
      }
      m.run { c in
        _ = c[source]
        order.append(3)
      }
    }
  ])

  cogs.commit(secondAlive, to: false)
  m.run { c in
    _ = c[source]
    order.append(4)
  }

  order.removeAll()
  cogs.commit { c in c[source] = 1 }

  #expect(order == [1, 3, 4])
}

@MainActor
@Test func `REACT-06 every run replaces the reaction dependency set`() {
  let useX = ManualCog<Bool>(true)
  let x = ManualCog<Int>(1)
  let y = ManualCog<Int>(10)
  var seen: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        seen.append(c[useX] ? c[x] : c[y])
      }
    }
  ])

  cogs.commit { c in c[y] = 11 }
  #expect(seen == [1])

  cogs.commit { c in c[useX] = false }
  #expect(seen == [1, 11])

  cogs.commit { c in c[y] = 12 }
  #expect(seen == [1, 11, 12])

  cogs.commit { c in c[x] = 2 }
  #expect(seen == [1, 11, 12])
}

@MainActor
@Test func `REACT-23 flush-time registrations join the reaction queue tail`() {
  let trigger = ManualCog<Int>(0)
  let writeback = ManualCog<Int>(0)
  var events: [String] = []
  var spawned = 0
  var m: MechanismController!

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { controller in
      m = controller
      m.run { c in
        guard c[trigger] == 1 else { return }

        events.append("first:begin")
        m.run { c in
          _ = c[trigger]
          events.append("third:initial")
          m.commit("third.writeback") { c in c[writeback] = 1 }
        }
        spawned += 1
        m.run { c in
          _ = c[trigger]
          events.append("fourth:initial")
          m.commit("fourth.writeback") { c in c[writeback] = 2 }
        }
        spawned += 1
        events.append("first:end")
      }

      m.run { c in
        guard c[trigger] == 1 else { return }
        events.append("second")
      }

      m.run { c in
        let value = c[writeback]
        guard value > 0 else { return }
        events.append("writeback:\(value)")
      }
    }
  ])

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
  #expect(spawned == 2)
}

@MainActor
@Test func `REACT-15 REACT-16 reaction write-back chains drain settled and FIFO`() {
  // The first hop is REACT-15: `second` wakes exactly once, after `first`'s
  // whole body ran, seeing middle already settled — the reaction's op landed
  // as a brand-new turn after the flush, never a change to the turn being
  // flushed and never a synchronous nested flush (that would run `third`
  // before `side`). The rest of the chain is REACT-16: each queued turn runs
  // first-in first-out, fully settled.
  let trigger = ManualCog<Int>(0)
  let middle = ManualCog<Int>(0)
  let side = ManualCog<Int>(0)
  let leaf = ManualCog<Int>(0)
  var events: [String] = []
  var reactionDepth = 0
  var maximumDepth = 0

  var cogs: Cogs!
  func record(_ name: String) {
    reactionDepth += 1
    maximumDepth = max(maximumDepth, reactionDepth)
    defer { reactionDepth -= 1 }
    events.append(
      "\(name):\(cogs.peek(trigger))/\(cogs.peek(middle))/\(cogs.peek(side))/\(cogs.peek(leaf))"
    )
  }

  cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        guard c[trigger] == 1 else { return }
        record("first")
        m.setFromReaction(middle, to: 1)
        m.setFromReaction(side, to: 1)
      }

      m.run { c in
        guard c[middle] == 1 else { return }
        record("second")
        m.setFromReaction(leaf, to: 1)
      }

      m.run { c in
        guard c[side] == 1 else { return }
        record("side")
      }

      m.run { c in
        guard c[leaf] == 1 else { return }
        record("third")
      }
    }
  ])

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
}

@MainActor
@Test func `REACT-16 a watch sees every queued write-back value with true old-new pairs`() {
  // The same FIFO chain observed through `watch` instead of `run`: each queued
  // turn is its own delivery, no intermediate value is skipped, and every old
  // half really is the previous turn's value.
  let trigger = ManualCog<Int>(0)
  let count = ManualCog<Int>(0)
  var deliveries: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        guard c[trigger] == 1 else { return }
        m.setFromReaction(count, to: 1)
      }
      m.run { c in
        guard c[count] == 1 else { return }
        m.setFromReaction(count, to: 2)
      }
      m.watch(count, initial: .skip, name: "watch.chain") { old, new in
        deliveries.append("\(old)->\(new)")
      }
    }
  ])

  cogs.commit { c in c[trigger] = 1 }

  #expect(deliveries == ["0->1", "1->2"])
}
