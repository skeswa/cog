import Cog
import CogTesting
import Testing

@MainActor
@Test func `CYCLE-04 a conditional cycle is caught only after its condition flips`() {
  let cogs = Cogs.forTesting()
  let closesCycle = Cog<Bool>.Manual { false }
  var diagnostic: CogCycleDiagnostic?
  var conditional: Cog<Int>!

  conditional = Cog<Int>(
    { c in
      guard c[closesCycle] else { return 42 }
      if let cycle = c.cycleDiagnostic(ifReading: conditional) {
        diagnostic = cycle
        return -1
      }
      return c[conditional]
    },
    name: "conditional"
  )

  #expect(cogs.peek(conditional) == 42)
  #expect(diagnostic == nil)

  cogs.turn { c in c[closesCycle] = true }

  #expect(cogs.peek(conditional) == -1)
  #expect(diagnostic?.path == ["conditional", "conditional"])
}
