import Cog
import CogTesting
import Testing

// Selector-owned counters prove run counts without inspecting graph storage.

// MARK: - READ-02

@MainActor
@Test func `READ-02 any number of reads with nothing changing is still one run`() {
  var runs = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(5)
  let doubled = Cog<Int> { c in
    runs += 1
    return c[source] * 2
  }

  for _ in 0..<50 {
    #expect(cogs.peek(doubled) == 10)
  }

  #expect(runs == 1)
}

@MainActor
@Test func `READ-02 a shared automatic cog runs once for all its readers`() {
  // The cache belongs to the cog, not to the reader, so a value two consumers
  // both need is computed once — the property that keeps a diamond from
  // computing its shared parent twice.
  var sharedRuns = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(4)
  let shared = Cog<Int> { c in
    sharedRuns += 1
    return c[source] * 2
  }
  let left = Cog<Int> { c in c[shared] + 1 }
  let right = Cog<Int> { c in c[shared] - 1 }

  #expect(cogs.peek(left) == 9)
  #expect(cogs.peek(right) == 7)
  #expect(cogs.peek(shared) == 8)

  #expect(sharedRuns == 1)
}

@MainActor
@Test func `READ-02 a cached optional nil value is still a cache hit`() {
  // "Has this run?" and "did it produce nil?" are different questions. A cog
  // that computed `nil` has run, and reading it again must not run it again.
  var runs = 0

  let cogs = Cogs.forTesting()
  let rawZip = ManualCog<String>("")
  let currentZip = Cog<String?> { c in
    runs += 1
    let raw = c[rawZip]
    return raw.isEmpty ? nil : raw
  }

  #expect(cogs.peek(currentZip) == nil)
  #expect(cogs.peek(currentZip) == nil)

  #expect(runs == 1)
}

@MainActor
@Test func `READ-02 each context caches for itself`() {
  // One declaration, two runtimes: a value computed in a test's context is not
  // a value another test's context can hand back.
  var runs = 0

  let first = Cogs.forTesting()
  let second = Cogs.forTesting()
  let source = ManualCog<Int>(6)
  let doubled = Cog<Int> { c in
    runs += 1
    return c[source] * 2
  }

  #expect(first.peek(doubled) == 12)
  #expect(second.peek(doubled) == 12)
  #expect(runs == 2)

  #expect(first.peek(doubled) == 12)
  #expect(second.peek(doubled) == 12)
  #expect(runs == 2)
}

// MARK: - READ-03

@MainActor
@Test func `READ-03 one turn presents two changed sources as one settled pair`() {
  var pairsSeen: [String] = []

  let cogs = Cogs.forTesting()
  let left = ManualCog<Int>(1)
  let right = ManualCog<Int>(10)
  let pair = Cog<String> { c in
    let currentLeft = c[left]
    let currentRight = c[right]
    let snapshot = "\(currentLeft):\(currentRight)"
    pairsSeen.append(snapshot)
    return snapshot
  }

  #expect(cogs.peek(pair) == "1:10")

  cogs.turn { c in
    c[left] = 2
    c[right] = 20
  }

  #expect(cogs.peek(pair) == "2:20")
  #expect(pairsSeen == ["1:10", "2:20"])
}
