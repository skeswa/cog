import Cog
import CogTesting
import Testing

// Watch behavior is proved through the public mechanism registration, write,
// and turn APIs only. Each watch registers during assembly, so its install
// delivery happens before the factory returns.

@MainActor
@Test func `REACT-08 a skipping watch is quiet at install and then delivers old and new`() {
  let source = Cog<Int>.Manual(1)
  let doubled = Cog<Int> { c in c[source] * 2 }
  var deliveries: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.watch(doubled, initial: .skip, name: "watch.skipping") { old, new in
        deliveries.append("\(old)->\(new)")
      }
    }
  ])

  // Installing the watch calls nothing at all.
  #expect(deliveries.isEmpty)

  cogs.turn { c in c[source] = 2 }

  // The first real change calls once, with the value from before the change
  // and the value after it.
  #expect(deliveries == ["2->4"])

  cogs.turn { c in c[source] = 3 }

  // The old value advances with the watch, so it really is the previous value
  // rather than the one captured at install time.
  #expect(deliveries == ["2->4", "4->6"])
}

@MainActor
@Test func `REACT-09 a running watch calls the body once at install time`() {
  let source = Cog<Int>.Manual(1)
  var deliveries: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.watch(source, initial: .run, name: "watch.running") { old, new in
        deliveries.append("\(old)->\(new)")
      }
    }
  ])

  // Once, and before assembly returns — no await and no polling. An install
  // has no transition to report, so the current value is both halves.
  #expect(deliveries == ["1->1"])

  cogs.turn { c in c[source] = 2 }

  // After its install call it is an ordinary watch.
  #expect(deliveries == ["1->1", "1->2"])
}
