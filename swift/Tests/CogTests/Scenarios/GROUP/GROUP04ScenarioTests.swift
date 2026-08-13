import Cog
import CogTesting
import Testing

@MainActor
@Test func `GROUP-04 dropping the final group reference cancels its effects`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []
  var group: EffectGroup? = EffectGroup()

  group?.add(cogs.run { c in seen.append(c[source]) })
  #expect(seen == [0])

  group = nil
  cogs.commit { c in c[source] = 1 }

  #expect(seen == [0])
  #expect(cogs.peek(source) == 1)
}
