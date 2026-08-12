import Cog
import CogTesting
import Testing

// Selector-owned counters prove run counts without inspecting graph storage.

// MARK: - READ-02

@MainActor
@Test func `READ-02 a second read of a derived cog uses the cache`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let price = ManualCog<Int>(7)
  let quantity = ManualCog<Int>(3)
  let total = Cog<Int> { c in
    runs += 1
    return c.get(price) * c.get(quantity)
  }

  #expect(cogs.read(total) == 21)
  #expect(cogs.read(total) == 21)

  #expect(runs == 1)
}

@MainActor
@Test func `READ-02 any number of reads with nothing changing is still one run`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(5)
  let doubled = Cog<Int> { c in
    runs += 1
    return c.get(source) * 2
  }

  for _ in 0..<50 {
    #expect(cogs.read(doubled) == 10)
  }

  #expect(runs == 1)
}

@MainActor
@Test func `READ-02 a shared derived cog runs once for all its readers`() {
  // The cache belongs to the cog, not to the reader, so a value two consumers
  // both need is computed once — the property that keeps a diamond from
  // computing its shared parent twice.
  var sharedRuns = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(4)
  let shared = Cog<Int> { c in
    sharedRuns += 1
    return c.get(source) * 2
  }
  let left = Cog<Int> { c in c.get(shared) + 1 }
  let right = Cog<Int> { c in c.get(shared) - 1 }

  #expect(cogs.read(left) == 9)
  #expect(cogs.read(right) == 7)
  #expect(cogs.read(shared) == 8)

  #expect(sharedRuns == 1)
}

@MainActor
@Test func `READ-02 a cached optional nil value is still a cache hit`() {
  // "Has this run?" and "did it produce nil?" are different questions. A cog
  // that computed `nil` has run, and reading it again must not run it again.
  var runs = 0

  let cogs = Cogtext.forTesting()
  let rawZip = ManualCog<String>("")
  let currentZip = Cog<String?> { c in
    runs += 1
    let raw = c.get(rawZip)
    return raw.isEmpty ? nil : raw
  }

  #expect(cogs.read(currentZip) == nil)
  #expect(cogs.read(currentZip) == nil)

  #expect(runs == 1)
}

@MainActor
@Test func `READ-02 each context caches for itself`() {
  // One declaration, two runtimes: a value computed in a test's context is not
  // a value another test's context can hand back.
  var runs = 0

  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()
  let source = ManualCog<Int>(6)
  let doubled = Cog<Int> { c in
    runs += 1
    return c.get(source) * 2
  }

  #expect(first.read(doubled) == 12)
  #expect(second.read(doubled) == 12)
  #expect(runs == 2)

  #expect(first.read(doubled) == 12)
  #expect(second.read(doubled) == 12)
  #expect(runs == 2)
}

// MARK: - READ-03

@MainActor
@Test func `READ-03 one commit presents two changed sources as one settled pair`() {
  var pairsSeen: [String] = []

  let cogs = Cogtext.forTesting()
  let left = ManualCog<Int>(1)
  let right = ManualCog<Int>(10)
  let pair = Cog<String> { c in
    let currentLeft = c.get(left)
    let currentRight = c.get(right)
    let snapshot = "\(currentLeft):\(currentRight)"
    pairsSeen.append(snapshot)
    return snapshot
  }

  #expect(cogs.read(pair) == "1:10")

  cogs.commit { w in
    w[left] = 2
    w[right] = 20
  }

  #expect(cogs.read(pair) == "2:20")
  #expect(pairsSeen == ["1:10", "2:20"])
}
