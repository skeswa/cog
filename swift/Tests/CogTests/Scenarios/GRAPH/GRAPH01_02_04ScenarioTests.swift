import Cog
import CogTesting
import Testing

// Derived-value scenarios written against the public `Cog` API and the
// `CogTesting` product and nothing else — no `@testable`, no state storage, no
// internal counters. That is scenarios.md constraint 3, and run-count claims
// are exactly the place it would be tempting to break: the implementation
// knows them precisely and the public API does not expose them at all.
//
// The way to ask "did it run?" without reaching inside is to make the selector
// itself do the counting. A counter the test owns, incremented in the closure
// the test wrote, is public-API observable by construction — the library never
// sees it — and it keeps saying the same thing after the M6 core swap, which is
// what COUNT-09 through COUNT-11 require of this whole suite.
//
// Value references are declared inside each test rather than at file scope,
// and every test states `@MainActor`, so all four matrix legs say the same
// thing (§7).

// MARK: - GRAPH-01

@MainActor
@Test func `GRAPH-01 a changed source settles a derived chain before the read returns`() {
  var middleRuns = 0
  var rootRuns = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let middle = Cog<Int> { c in
    middleRuns += 1
    return c.get(source) + 1
  }
  let root = Cog<Int> { c in
    rootRuns += 1
    return c.get(middle) * 2
  }

  #expect(cogs.read(root) == 4)
  #expect(middleRuns == 1)
  #expect(rootRuns == 1)

  cogs.commit { w in w[source] = 10 }

  // The read is the pull boundary: it returns only after every dependency it
  // needs has caught up to the newest committed source value.
  #expect(cogs.read(root) == 22)
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

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let left = Cog<Int> { c in
    leftRuns += 1
    return c.get(source) + 1
  }
  let right = Cog<Int> { c in
    rightRuns += 1
    return c.get(source) * 10
  }
  let root = Cog<Int> { c in
    rootRuns += 1
    let currentLeft = c.get(left)
    let currentRight = c.get(right)
    rootPairs.append("\(currentLeft):\(currentRight)")
    return currentLeft + currentRight
  }

  #expect(cogs.read(root) == 12)

  cogs.commit { w in w[source] = 3 }

  #expect(cogs.read(root) == 34)
  #expect(leftRuns == 2)
  #expect(rightRuns == 2)
  #expect(rootRuns == 2)
  #expect(rootPairs == ["2:10", "4:30"])
}

// MARK: - GRAPH-04

@MainActor
@Test func `GRAPH-04 a broad pull recomputes only the branches it reads`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let breadth = 64
  var runs = Array(repeating: 0, count: breadth)

  let branches = (0..<breadth).map { branch in
    Cog<Int> { c in
      runs[branch] += 1
      return c.get(source) + branch
    }
  }

  // Warm every sibling so the source really feeds a broad live graph before
  // the turn. Never-created branches would prove declaration laziness instead.
  for branch in 0..<breadth {
    #expect(cogs.read(branches[branch]) == 1 + branch)
  }
  #expect(runs == Array(repeating: 1, count: breadth))

  cogs.commit { w in w[source] = 10 }
  #expect(cogs.read(source) == 10)
  #expect(runs == Array(repeating: 1, count: breadth))

  let selected = [0, 7, 31, 63]
  for branch in selected {
    #expect(cogs.read(branches[branch]) == 10 + branch)
  }

  let expectedRuns = (0..<breadth).map { branch in
    selected.contains(branch) ? 2 : 1
  }
  #expect(runs == expectedRuns)
}
