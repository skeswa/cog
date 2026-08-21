import Cog
import CogTesting
import Testing

@MainActor
@Test func `MECH-01 bootstrap operates mechanisms synchronously in list order`() {
  let source = ManualCog<Int>(0)
  var events: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe(name: "First") { m in
      events.append("operate:First")
      m.run { c in
        guard c[source] > 0 else { return }
        events.append("react:First")
      }
    },
    MechanismProbe(name: "Second") { m in
      events.append("operate:Second")
      m.run { c in
        guard c[source] > 0 else { return }
        events.append("react:Second")
      }
    },
  ])

  // Each `operate` ran synchronously, in list order, before the factory
  // returned — no await, no later start signal.
  #expect(events == ["operate:First", "operate:Second"])

  // Every mechanism is live on the very next line: one turn wakes both, and
  // their reactions run in list order because registration order is list
  // order.
  cogs.turn { c in c[source] = 1 }
  #expect(events == ["operate:First", "operate:Second", "react:First", "react:Second"])
}

@MainActor
@Test func `MECH-02 operate-time writes settle before bootstrap returns`() {
  let configured = ManualCog<Int>(0)
  var laterMechanismSaw: Int?

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe(name: "Configurer") { m in
      m.turn("configure") { c in c[configured] = 7 }
    },
    MechanismProbe(name: "Observer") { m in
      // The earlier mechanism's turn has already settled: a later mechanism
      // observes the published value during its own `operate`.
      laterMechanismSaw = m.peek(configured)
    },
  ])

  #expect(laterMechanismSaw == 7)
  #expect(cogs.peek(configured) == 7)
}
