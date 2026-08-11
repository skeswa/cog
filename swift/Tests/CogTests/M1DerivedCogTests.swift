import Cog
import CogTesting
import Testing

// The three scenarios `M1-05a` greens, written against the public `Cog` API and
// the `CogTesting` product and nothing else — no `@testable`, no node storage,
// no internal counters. That is scenarios.md constraint 3, and DECL-09 and
// READ-02 are exactly the place it would be tempting to break: both are claims
// about *how much work ran*, which the implementation knows precisely and the
// public API does not expose at all.
//
// The way to ask "did it run?" without reaching inside is to make the selector
// itself do the counting. A counter the test owns, incremented in the closure
// the test wrote, is public-API observable by construction — the library never
// sees it — and it keeps saying the same thing after the M6 core swap, which is
// what COUNT-09 through COUNT-11 require of this whole suite.
//
// Refs are declared inside each test rather than at file scope, and every test
// states `@MainActor`, for the reason `M1CogtextReadTests.swift` gives: a
// file-scope `let` would say different things in the MainActor and nonisolated
// legs of the matrix (§7).
//
// The GRAPH-01 section is the first write-after-compute behavior. It stays on
// the same public surface: selector-owned counters show which cached nodes ran
// again, without exposing settle flags, versions, or the explicit stack.

// MARK: - DECL-07

@MainActor
@Test func `DECL-07 a derived cog reads back what its selector computed`() {
  let cogs = Cogtext.forTesting()

  let width = ManualCog<Int>(3)
  let height = ManualCog<Int>(4)
  let area = Cog<Int> { c in c.get(width) * c.get(height) }

  #expect(cogs.read(area) == 12)
}

@MainActor
@Test func `DECL-07 a derived cog computes from whatever its sources hold`() {
  // Two contexts, one declaration, different source values: the derived value
  // follows the state it was computed from rather than the declaration.
  let quiet = Cogtext.forTesting()
  let busy = Cogtext.forTesting()

  let attempts = ManualCog<Int>(0)
  let hasRetried = Cog<Bool> { c in c.get(attempts) > 1 }

  busy.commit { w in w[attempts] = 4 }

  #expect(quiet.read(hasRetried) == false)
  #expect(busy.read(hasRetried) == true)
}

@MainActor
@Test func `DECL-07 a derived cog can compute from another derived cog`() {
  // `c.get` reads a derived cog the same way it reads a source, so a chain is
  // written the same way a leaf is — and reading the top computes the whole
  // chain (§2.2).
  let cogs = Cogtext.forTesting()

  let celsius = ManualCog<Double>(100)
  let fahrenheit = Cog<Double> { c in c.get(celsius) * 9 / 5 + 32 }
  let isBoiling = Cog<Bool> { c in c.get(fahrenheit) >= 212 }
  let advice = Cog<String> { c in c.get(isBoiling) ? "wait" : "drink" }

  #expect(cogs.read(fahrenheit) == 212)
  #expect(cogs.read(advice) == "wait")
}

@MainActor
@Test func `DECL-07 a derived cog's selector is an ordinary function`() {
  // Branches, early returns, and locals are all fine: a selector is normal
  // Swift, and the dependencies are whatever the run actually read (§2.4).
  let cogs = Cogtext.forTesting()

  let currentZip = ManualCog<String?>(nil)
  let knownZips = ManualCog<[String]>(["90210"])

  let isKnownZip = Cog<Bool> { c in
    guard let zip = c.get(currentZip) else { return false }
    return c.get(knownZips).contains(zip)
  }

  #expect(cogs.read(isKnownZip) == false)
}

@MainActor
@Test func `DECL-07 a derived cog may compute an optional value`() {
  // A derived cog whose value is itself optional is not a special case: `nil`
  // is a computed value like any other.
  let cogs = Cogtext.forTesting()

  let rawZip = ManualCog<String>("")
  let currentZip = Cog<String?> { c in
    let raw = c.get(rawZip)
    return raw.isEmpty ? nil : raw
  }

  #expect(cogs.read(currentZip) == nil)
}

// MARK: - DECL-09

@MainActor
@Test func `DECL-09 declaring a derived cog runs nothing`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in
    runs += 1
    return c.get(source) * 2
  }

  // Declaring is the whole of what happened: no context was touched, so
  // nothing could have run.
  #expect(runs == 0)

  // Nor does using the context for something else wake it.
  #expect(cogs.read(source) == 1)
  cogs.commit { w in w[source] = 2 }
  #expect(runs == 0)

  // Keep the declaration alive to the end of the test so nothing above can be
  // explained away by the ref going out of scope.
  _ = doubled
}

@MainActor
@Test func `DECL-09 the first read is what runs the selector`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(21)
  let doubled = Cog<Int> { c in
    runs += 1
    return c.get(source) * 2
  }

  #expect(runs == 0)
  #expect(cogs.read(doubled) == 42)
  #expect(runs == 1)
}

@MainActor
@Test func `DECL-09 a derived cog nobody reads never runs`() {
  var readRuns = 0
  var unreadRuns = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let read = Cog<Int> { c in
    readRuns += 1
    return c.get(source)
  }
  let unread = Cog<Int> { c in
    unreadRuns += 1
    return c.get(source)
  }

  #expect(cogs.read(read) == 1)

  #expect(readRuns == 1)
  #expect(unreadRuns == 0)
}

@MainActor
@Test func `DECL-09 an unread branch of a chain never runs`() {
  // Laziness is transitive, which is what makes it worth having: reading the
  // bottom of a chain does not drag the rest of the graph along.
  var innerRuns = 0
  var outerRuns = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(2)
  let inner = Cog<Int> { c in
    innerRuns += 1
    return c.get(source) * 2
  }
  let outer = Cog<Int> { c in
    outerRuns += 1
    return c.get(inner) * 2
  }

  #expect(cogs.read(inner) == 4)
  #expect(innerRuns == 1)
  #expect(outerRuns == 0)

  // Reading the outer one now runs it, and does not run the inner one again.
  #expect(cogs.read(outer) == 8)
  #expect(innerRuns == 1)
  #expect(outerRuns == 1)
}

@MainActor
@Test func `DECL-09 a context that never sees a declaration runs nothing`() {
  // The declaration is one thing; the running of it is per context (§2.3). A
  // second context has run nothing until it is asked.
  var runs = 0

  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in
    runs += 1
    return c.get(source) * 2
  }

  #expect(first.read(doubled) == 2)
  #expect(runs == 1)

  _ = second.read(source)
  #expect(runs == 1)
}

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
  // computing its shared parent twice (§2.2).
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
  // a value another test's context can hand back (§2.3).
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
