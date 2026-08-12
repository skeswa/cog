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
  // explained away by the value reference going out of scope.
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
