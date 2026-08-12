import Cog
import CogTesting
import Testing

// MARK: - READ-07

@MainActor
@Test func `READ-07 peek settles without subscribing`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var inputsSeen: [Int] = []
  let doubled = Cog<Int> { c in
    let input = c[source]
    inputsSeen.append(input)
    return input * 2
  }

  #expect(cogs.peek(doubled) == 2)

  cogs.commit { c in c[source] = 2 }
  #expect(inputsSeen == [1])
  #expect(cogs.peek(doubled) == 4)
  #expect(inputsSeen == [1, 2])

  // The catch-up read above must not leave the root hot. A later turn dirties
  // it but does not run it, and another peek still settles it.
  cogs.commit { c in c[source] = 3 }
  #expect(cogs.peek(source) == 3)
  #expect(inputsSeen == [1, 2])
  #expect(cogs.peek(doubled) == 6)
  #expect(inputsSeen == [1, 2, 3])
}

@MainActor
@Test func `READ-07 peek creates no dependency on its ambient selector`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let trigger = ManualCog<Int>(0)
  var innerInputs: [Int] = []
  var outerRuns = 0

  let doubled = Cog<Int> { c in
    let input = c[source]
    innerInputs.append(input)
    return input * 2
  }
  let snapshot = Cog<Int> { c in
    _ = c[trigger]
    outerRuns += 1
    return cogs.peek(doubled)
  }

  #expect(cogs.peek(snapshot) == 2)
  #expect(innerInputs == [1])
  #expect(outerRuns == 1)

  cogs.commit { c in
    c[source] = 2
    c[trigger] = 1
  }
  #expect(innerInputs == [1])
  #expect(cogs.peek(snapshot) == 4)
  #expect(innerInputs == [1, 2])
  #expect(outerRuns == 2)

  // A source-only turn dirties the inner cog. If the peek had linked
  // it to the ambient selector, pulling the selector would now rerun it.
  cogs.commit { c in c[source] = 3 }
  #expect(cogs.peek(source) == 3)
  #expect(innerInputs == [1, 2])
  #expect(cogs.peek(snapshot) == 4)
  #expect(outerRuns == 2)
  #expect(cogs.peek(doubled) == 6)
  #expect(innerInputs == [1, 2, 3])
}
