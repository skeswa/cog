import Cog
import CogTesting
import Testing

@MainActor
@Test func `MECH-03 a mechanism left off the assembly list never runs`() {
  let source = Cog<Int>.Manual { 0 }
  var listedRuns = 0
  var unlistedRuns = 0

  // Declaring a mechanism does nothing by itself: this value exists for the
  // whole test and its `operate` is never called.
  let unlisted = MechanismProbe(name: "Unlisted") { m in
    unlistedRuns += 1
    m.run { c in
      _ = c[source]
      unlistedRuns += 1
    }
  }

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe(name: "Listed") { m in
      m.run { c in
        _ = c[source]
        listedRuns += 1
      }
    }
  ])

  #expect(listedRuns == 1)
  #expect(unlistedRuns == 0)

  // A real turn wakes only the listed mechanism's reaction; the declared but
  // unlisted mechanism still has nothing registered.
  cogs.turn { c in c[source] = 1 }
  #expect(listedRuns == 2)
  #expect(unlistedRuns == 0)
  _ = unlisted
}
