import Cog
import CogTesting
import Testing

// Selector-owned counters prove run counts without inspecting graph storage.

// MARK: - GRAPH-01

@MainActor
@Test func `GRAPH-01 a changed source settles an automatic chain before the read returns`() {
  var middleRuns = 0
  var rootRuns = 0

  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(1)
  let middle = Cog<Int> { c in
    middleRuns += 1
    return c[source] + 1
  }
  let root = Cog<Int> { c in
    rootRuns += 1
    return c[middle] * 2
  }

  #expect(cogs.peek(root) == 4)
  #expect(middleRuns == 1)
  #expect(rootRuns == 1)

  cogs.turn { c in c[source] = 10 }

  // The read is the pull boundary: it returns only after every dependency it
  // needs has caught up to the newest published source value.
  #expect(cogs.peek(root) == 22)
  #expect(middleRuns == 2)
  #expect(rootRuns == 2)
}

// MARK: - GRAPH-02

@MainActor
@Test func `GRAPH-02 a diamond settles both arms and its root exactly once`() {
  var leftRuns = 0
  var rightRuns = 0
  var rootRuns = 0
  var rootPairs: [String] = []

  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(1)
  let left = Cog<Int> { c in
    leftRuns += 1
    return c[source] + 1
  }
  let right = Cog<Int> { c in
    rightRuns += 1
    return c[source] * 10
  }
  let root = Cog<Int> { c in
    rootRuns += 1
    let currentLeft = c[left]
    let currentRight = c[right]
    rootPairs.append("\(currentLeft):\(currentRight)")
    return currentLeft + currentRight
  }

  #expect(cogs.peek(root) == 12)

  cogs.turn { c in c[source] = 3 }

  #expect(cogs.peek(root) == 34)
  #expect(leftRuns == 2)
  #expect(rightRuns == 2)
  #expect(rootRuns == 2)
  #expect(rootPairs == ["2:10", "4:30"])
}

// MARK: - GRAPH-04

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
