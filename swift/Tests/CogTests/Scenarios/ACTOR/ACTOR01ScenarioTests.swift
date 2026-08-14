import Cog
import CogTesting
import Testing

@MainActor
@Test func `ACTOR-01 derived selectors execute on the MainActor`() {
  let (cogs, m) = probedContext()
  let source = ManualCog<Int>(21)
  var selectorRuns = 0
  let doubled = Cog<Int> { c in
    MainActor.preconditionIsolated("Cog selector")
    selectorRuns += 1
    return c[source] * 2
  }

  #expect(cogs.peek(doubled) == 42)
  #expect(selectorRuns == 1)
}

@MainActor
@Test func `ACTOR-01 commit bodies execute on the MainActor`() {
  let (cogs, m) = probedContext()
  let source = ManualCog<Int>(0)
  var bodyRuns = 0

  cogs.commit { c in
    MainActor.preconditionIsolated("Cog commit body")
    bodyRuns += 1
    c[source] = 1
  }

  #expect(bodyRuns == 1)
  #expect(cogs.peek(source) == 1)
}

@MainActor
@Test func `ACTOR-01 watch handlers execute on the MainActor`() {
  let (cogs, m) = probedContext()
  let source = ManualCog<Int>(1)
  var deliveries: [String] = []

  m.watch(source, initial: .run) { old, new in
    MainActor.preconditionIsolated("Cog watch handler")
    deliveries.append("\(old)->\(new)")
  }

  cogs.commit { c in c[source] = 2 }

  #expect(deliveries == ["1->1", "1->2"])
}

@MainActor
@Test func `ACTOR-01 reactions execute on the MainActor`() {
  let (cogs, m) = probedContext()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []

  m.run { c in
    MainActor.preconditionIsolated("Cog reaction")
    seen.append(c[source])
  }

  #expect(seen == [0])

  cogs.commit { c in c[source] = 1 }

  #expect(seen == [0, 1])
}
