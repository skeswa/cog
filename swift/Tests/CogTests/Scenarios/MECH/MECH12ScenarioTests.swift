#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func `MECH-12 the seeding closure runs before any operate`() {
  let currentZip = ManualCog<String?>(nil)
  var deliveries: [String] = []

  _ = Cogs.forTesting(
    seeding: { cogs in
      cogs.seed(currentZip, to: "90210")
    },
    mechanisms: [
      MechanismProbe { m in
        // Seeding preceded `operate`, so this `initial: .run` watch observes
        // the seeded value on its registration run instead of the
        // declaration default.
        m.watch(currentZip, initial: .run) { old, new in
          deliveries.append("\(old ?? "nil")->\(new ?? "nil")")
        }
      }
    ]
  )

  #expect(deliveries == ["90210->90210"])
}

#endif
