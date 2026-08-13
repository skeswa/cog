import Cog
import CogTesting
import Testing

@MainActor
@Test func `ACTOR-01 derived selectors execute on the MainActor`() {
  let cogs = Cogs.forTesting()
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
  let cogs = Cogs.forTesting()
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
@Test func `ACTOR-01 reactions execute on the MainActor`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []

  let token = cogs.run { c in
    MainActor.preconditionIsolated("Cog reaction")
    seen.append(c[source])
  }

  #expect(seen == [0])

  cogs.commit { c in c[source] = 1 }

  #expect(seen == [0, 1])
  _ = token
}
