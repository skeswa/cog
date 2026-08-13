import Cog
import CogTesting
import Testing

@MainActor
@Test func `GROUP-01 cancelling a group stops its watch`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []
  let group = EffectGroup()

  group.add(cogs.run { c in seen.append(c[source]) })
  #expect(seen == [0])

  group.cancel()
  cogs.commit { c in c[source] = 1 }

  #expect(seen == [0])
  #expect(cogs.peek(source) == 1)
}

@MainActor
@Test func `GROUP-03 cancelling a group twice is harmless`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var runs = 0
  let group = EffectGroup()

  group.add(
    cogs.run { c in
      _ = c[source]
      runs += 1
    })

  group.cancel()
  group.cancel()
  group.cancel()
  cogs.commit { c in c[source] = 1 }

  #expect(runs == 1)
}

@MainActor
@Test func `GROUP-05 copies share one terminal group`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []
  let group = EffectGroup()
  let copy = group

  group.add(cogs.run { c in seen.append(c[source]) })
  #expect(group === copy)

  copy.cancel()
  cogs.commit { c in c[source] = 1 }

  #expect(seen == [0])
  group.cancel()
}
