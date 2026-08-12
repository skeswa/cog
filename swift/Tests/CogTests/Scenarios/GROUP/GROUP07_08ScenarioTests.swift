import Cog
import CogTesting
import Testing

@MainActor private let screenValue = ManualCog<Int>(0)

@MainActor private struct ScreenEffects {
  let record: @MainActor (Int) -> Void

  func install(in cogs: Cogtext) -> EffectGroup {
    let group = EffectGroup()
    group.add(
      cogs.run { reader in
        record(reader.get(screenValue))
      })
    return group
  }
}

@MainActor
@Test func `GROUP-07 cancelling screen effects preserves app state`() {
  let cogs = Cogtext.forTesting()
  var seen: [Int] = []
  let group = ScreenEffects { seen.append($0) }.install(in: cogs)

  cogs.commit { writer in writer[screenValue] = 1 }
  #expect(seen == [0, 1])

  group.cancel()
  cogs.commit { writer in writer[screenValue] = 2 }

  #expect(seen == [0, 1])
  #expect(cogs.read(screenValue) == 2)
}

@MainActor
@Test func `GROUP-08 an effects declaration is inert until installation`() {
  let cogs = Cogtext.forTesting()
  var seen: [Int] = []
  let effects = ScreenEffects { seen.append($0) }

  cogs.commit { writer in writer[screenValue] = 1 }
  #expect(seen.isEmpty)

  let group = effects.install(in: cogs)
  #expect(seen == [1])

  cogs.commit { writer in writer[screenValue] = 2 }
  #expect(seen == [1, 2])
  group.cancel()
}
