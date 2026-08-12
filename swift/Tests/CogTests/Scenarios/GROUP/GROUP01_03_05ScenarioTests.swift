import Cog
import CogTesting
import Testing

@MainActor
@Test func `GROUP-01 cancelling a group stops its watch`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []
  let group = EffectGroup()

  group.add(cogs.run { reader in seen.append(reader.get(source)) })
  #expect(seen == [0])

  group.cancel()
  cogs.commit { writer in writer[source] = 1 }

  #expect(seen == [0])
  #expect(cogs.read(source) == 1)
}

@MainActor
@Test func `GROUP-03 cancelling a group twice is harmless`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var runs = 0
  let group = EffectGroup()

  group.add(
    cogs.run { reader in
      _ = reader.get(source)
      runs += 1
    })

  group.cancel()
  group.cancel()
  group.cancel()
  cogs.commit { writer in writer[source] = 1 }

  #expect(runs == 1)
}

@MainActor
@Test func `GROUP-05 copies share one terminal group`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []
  let group = EffectGroup()
  let copy = group

  group.add(cogs.run { reader in seen.append(reader.get(source)) })
  #expect(group === copy)

  copy.cancel()
  cogs.commit { writer in writer[source] = 1 }

  #expect(seen == [0])
  group.cancel()
}
