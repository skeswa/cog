import Cog
import CogTesting
import Testing

@MainActor
@Test func `CYCLE-03 a keyed cycle diagnostic includes every key`() {
  let cogs = Cogtext.forTesting()
  let holder = CycleDiagnosticBoxHolder()
  var diagnostic: CogCycleDiagnostic?

  holder.box = CogBox<Int, String>(
    { c, key in
      let next = holder.box[key == "home" ? "work" : "home"]
      if let cycle = c.cycleDiagnostic(ifReading: next) {
        diagnostic = cycle
        return 0
      }
      return c[next]
    },
    name: "weather"
  )

  #expect(cogs.peek(holder.box["home"]) == 0)
  #expect(diagnostic?.path == ["weather[home]", "weather[work]", "weather[home]"])
  #expect(
    diagnostic?.message
      == "Cog dependency cycle: weather[home] -> weather[work] -> weather[home]."
  )
}

@MainActor
@Test func `CYCLE-04 a conditional cycle is caught only after its condition flips`() {
  let cogs = Cogtext.forTesting()
  let closesCycle = ManualCog<Bool>(false)
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

  cogs.commit { c in c[closesCycle] = true }

  #expect(cogs.peek(conditional) == -1)
  #expect(diagnostic?.path == ["conditional", "conditional"])
}

@MainActor
@Test func `CYCLE-05 the testing seam diagnoses a cycle without crashing`() {
  let cogs = Cogtext.forTesting()
  var diagnostic: CogCycleDiagnostic?
  var selfReading: Cog<Int>!

  selfReading = Cog<Int>(
    { c in
      diagnostic = c.cycleDiagnostic(ifReading: selfReading)
      return diagnostic == nil ? 1 : 2
    },
    name: "safe diagnostic"
  )

  #expect(cogs.peek(selfReading) == 2)
  #expect(diagnostic?.path == ["safe diagnostic", "safe diagnostic"])
  #expect(diagnostic?.message == "Cog dependency cycle: safe diagnostic -> safe diagnostic.")
}

@MainActor
private final class CycleDiagnosticBoxHolder {
  var box: CogBox<Int, String>!
}
