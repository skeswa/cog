import Cog
import CogTesting
import Testing

@MainActor
@Test func `GROUP-04 dropping the final group reference cancels its effects`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []
  var group: EffectGroup? = EffectGroup()

  group?.add(cogs.run { reader in seen.append(reader.get(source)) })
  #expect(seen == [0])

  group = nil
  cogs.commit { writer in writer[source] = 1 }

  #expect(seen == [0])
  #expect(cogs.read(source) == 1)
}
