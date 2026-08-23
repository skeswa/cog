import Cog
import CogTesting
import Testing

// A reaction wakes for changes, not for turns. These prove the quiet side of
// that: a turn happened, work was done, and the reaction still did not run.
// Each test ends with a real change, so a reaction that had simply broken and
// stopped running altogether could not pass.

@MainActor
@Test func `REACT-21 an equal recomputation leaves a watching reaction quiet`() {
  let count = Cog<Int>.Manual(2)
  var parityRuns = 0
  let isEven = Cog<Bool> { c in
    parityRuns += 1
    return c[count] % 2 == 0
  }
  var reactionRuns = 0

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        _ = c[isEven]
        reactionRuns += 1
      }
    }
  ])

  #expect(parityRuns == 1)
  #expect(reactionRuns == 1)

  cogs.turn { c in c[count] = 4 }

  // The source really changed, so the automatic cog really recomputed — this is
  // not a turn that quietly did nothing.
  #expect(parityRuns == 2)
  #expect(cogs.peek(isEven) == true)
  // It landed on the value it already had, so nothing downstream changed and
  // the reaction never ran.
  #expect(reactionRuns == 1)

  cogs.turn { c in c[count] = 5 }

  // A recomputation that does change the value still wakes it.
  #expect(parityRuns == 3)
  #expect(reactionRuns == 2)
}

@MainActor
@Test func `REACT-22 an equal write leaves a reading reaction quiet`() {
  let source = Cog<Int>.Manual(7)
  var reactionRuns = 0

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        _ = c[source]
        reactionRuns += 1
      }
    }
  ])

  #expect(reactionRuns == 1)

  cogs.turn("write the same value") { c in c[source] = 7 }

  #expect(cogs.peek(source) == 7)
  #expect(reactionRuns == 1)

  cogs.turn("write a different value") { c in c[source] = 8 }

  #expect(reactionRuns == 2)
}

@MainActor
@Test func `REACT-22 an equal write leaves a watch quiet`() {
  // The same promise through the watch spelling, whose delivery of an old and
  // a new value would be meaningless if an equal write could reach it.
  let source = Cog<Int>.Manual(7)
  var deliveries: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.watch(source, initial: .skip) { old, new in
        deliveries.append("\(old)->\(new)")
      }
    }
  ])

  cogs.turn { c in c[source] = 7 }
  #expect(deliveries.isEmpty)

  cogs.turn { c in c[source] = 8 }
  #expect(deliveries == ["7->8"])
}
