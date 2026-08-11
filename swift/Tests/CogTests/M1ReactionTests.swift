import Cog
import CogTesting
import Testing

// Reaction behavior is proved through the public registration, read, and turn
// APIs. Tokens stay alive for the duration of each test so later cancellation
// semantics cannot turn these wake-up tests into lifetime tests by accident.

@MainActor
@Test func `REACT-01 run performs its initial tracking run immediately`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c.get(source))
  }

  #expect(seen == [1])
  _ = token
}

@MainActor
@Test func `REACT-02 changing a dependency wakes the reaction`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c.get(source))
  }

  cogs.commit { w in w[source] = 2 }

  #expect(seen == [1, 2])
  _ = token
}

@MainActor
@Test func `REACT-03 an unrelated turn leaves the reaction quiet`() {
  let cogs = Cogtext.forTesting()
  let observed = ManualCog<Int>(1)
  let unrelated = ManualCog<Int>(10)
  var runs = 0

  let token = cogs.run { c in
    _ = c.get(observed)
    runs += 1
  }

  cogs.commit { w in w[unrelated] = 11 }

  #expect(runs == 1)
  _ = token
}

@MainActor
@Test func `REACT-04 dependencies settle before the reaction body starts`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var events: [String] = []
  let doubled = Cog<Int> { c in
    let value = c.get(source) * 2
    events.append("derive:\(value)")
    return value
  }

  let token = cogs.run { c in
    events.append("react:begin")
    events.append("react:value:\(c.get(doubled))")
  }

  events.removeAll()
  cogs.commit { w in w[source] = 2 }

  #expect(events == ["derive:4", "react:begin", "react:value:4"])
  _ = token
}

@MainActor
@Test func `REACT-05 changed reactions run in registration order`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var order: [Int] = []

  let first = cogs.run { c in
    _ = c.get(source)
    order.append(1)
  }
  let second = cogs.run { c in
    _ = c.get(source)
    order.append(2)
  }
  let third = cogs.run { c in
    _ = c.get(source)
    order.append(3)
  }

  order.removeAll()
  cogs.commit { w in w[source] = 1 }

  #expect(order == [1, 2, 3])
  _ = (first, second, third)
}

@MainActor
@Test func `REACT-06 every run replaces the reaction dependency set`() {
  let cogs = Cogtext.forTesting()
  let useX = ManualCog<Bool>(true)
  let x = ManualCog<Int>(1)
  let y = ManualCog<Int>(10)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c.get(useX) ? c.get(x) : c.get(y))
  }

  cogs.commit { w in w[y] = 11 }
  #expect(seen == [1])

  cogs.commit { w in w[useX] = false }
  #expect(seen == [1, 11])

  cogs.commit { w in w[y] = 12 }
  #expect(seen == [1, 11, 12])

  cogs.commit { w in w[x] = 2 }
  #expect(seen == [1, 11, 12])
  _ = token
}
