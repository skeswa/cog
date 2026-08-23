import Cog
import CogTesting
import Testing

// Selector-owned counters prove run counts without inspecting graph storage.

@MainActor
@Test func `GRAPH-04 a broad pull recomputes only the branches it reads`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(1)
  let breadth = 64
  var runs = Array(repeating: 0, count: breadth)

  let branches = (0..<breadth).map { branch in
    Cog<Int> { c in
      runs[branch] += 1
      return c[source] + branch
    }
  }

  // Warm every sibling so the source really feeds a broad live graph before
  // the turn. Never-created branches would prove declaration laziness instead.
  for branch in 0..<breadth {
    #expect(cogs.peek(branches[branch]) == 1 + branch)
  }
  #expect(runs == Array(repeating: 1, count: breadth))

  cogs.turn { c in c[source] = 10 }
  #expect(cogs.peek(source) == 10)
  #expect(runs == Array(repeating: 1, count: breadth))

  let selected = [0, 7, 31, 63]
  for branch in selected {
    #expect(cogs.peek(branches[branch]) == 10 + branch)
  }

  let expectedRuns = (0..<breadth).map { branch in
    selected.contains(branch) ? 2 : 1
  }
  #expect(runs == expectedRuns)
}
