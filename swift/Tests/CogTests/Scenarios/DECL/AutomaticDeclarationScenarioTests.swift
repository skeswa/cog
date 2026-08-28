import Cog
import CogTesting
import Testing

// Selector-owned counters prove run counts without inspecting graph storage.

// MARK: - DECL-07

@MainActor
@Test func `DECL-07 an automatic cog reads back what its selector computed`() {
  let cogs = Cogs.forTesting()

  let width = Cog<Int>.Manual { 3 }
  let height = Cog<Int>.Manual { 4 }
  let area = Cog<Int> { c in c[width] * c[height] }

  #expect(cogs.peek(area) == 12)
}

@MainActor
@Test func `DECL-07 an automatic cog computes from whatever its sources hold`() {
  // Two contexts, one declaration, different source values: the automatic value
  // follows the state it was computed from rather than the declaration.
  let quiet = Cogs.forTesting()
  let busy = Cogs.forTesting()

  let attempts = Cog<Int>.Manual { 0 }
  let hasRetried = Cog<Bool> { c in c[attempts] > 1 }

  busy.turn { c in c[attempts] = 4 }

  #expect(quiet.peek(hasRetried) == false)
  #expect(busy.peek(hasRetried) == true)
}

@MainActor
@Test func `DECL-07 an automatic cog can compute from another automatic cog`() {
  // `c[valueReference]` reads an automatic cog like a source. A chain uses the
  // same syntax as a leaf, and reading the top computes the whole chain.
  let cogs = Cogs.forTesting()

  let celsius = Cog<Double>.Manual { 100 }
  let fahrenheit = Cog<Double> { c in c[celsius] * 9 / 5 + 32 }
  let isBoiling = Cog<Bool> { c in c[fahrenheit] >= 212 }
  let advice = Cog<String> { c in c[isBoiling] ? "wait" : "drink" }

  #expect(cogs.peek(fahrenheit) == 212)
  #expect(cogs.peek(advice) == "wait")
}

@MainActor
@Test func `DECL-07 an automatic cog's selector is an ordinary function`() {
  // Branches, early returns, and locals are all fine: a selector is normal
  // Swift, and the dependencies are whatever the run actually read.
  let cogs = Cogs.forTesting()

  let currentZip = Cog<String?>.Manual { nil }
  let knownZips = Cog<[String]>.Manual { ["90210"] }

  let isKnownZip = Cog<Bool> { c in
    guard let zip = c[currentZip] else { return false }
    return c[knownZips].contains(zip)
  }

  #expect(cogs.peek(isKnownZip) == false)
}

@MainActor
@Test func `DECL-07 an automatic cog may compute an optional value`() {
  // An automatic cog whose value is itself optional is not a special case: `nil`
  // is a computed value like any other.
  let cogs = Cogs.forTesting()

  let rawZip = Cog<String>.Manual { "" }
  let currentZip = Cog<String?> { c in
    let raw = c[rawZip]
    return raw.isEmpty ? nil : raw
  }

  #expect(cogs.peek(currentZip) == nil)
}

// MARK: - DECL-09

@MainActor
@Test func `DECL-09 declaring an automatic cog runs nothing`() {
  var runs = 0

  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 1 }
  let doubled = Cog<Int> { c in
    runs += 1
    return c[source] * 2
  }

  // Declaring is the whole of what happened: no context was touched, so
  // nothing could have run.
  #expect(runs == 0)

  // Nor does using the context for something else wake it.
  #expect(cogs.peek(source) == 1)
  cogs.turn { c in c[source] = 2 }
  #expect(runs == 0)

  // Keep the declaration alive to the end of the test so nothing above can be
  // explained away by the value reference going out of scope.
  _ = doubled
}

@MainActor
@Test func `DECL-09 an automatic cog nobody reads never runs`() {
  var readRuns = 0
  var unreadRuns = 0

  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 1 }
  let read = Cog<Int> { c in
    readRuns += 1
    return c[source]
  }
  let unread = Cog<Int> { c in
    unreadRuns += 1
    return c[source]
  }

  #expect(cogs.peek(read) == 1)

  #expect(readRuns == 1)
  #expect(unreadRuns == 0)
}

@MainActor
@Test func `DECL-09 an unread branch of a chain never runs`() {
  // Laziness is transitive, which is what makes it worth having: reading the
  // bottom of a chain does not drag the rest of the graph along.
  var innerRuns = 0
  var outerRuns = 0

  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 2 }
  let inner = Cog<Int> { c in
    innerRuns += 1
    return c[source] * 2
  }
  let outer = Cog<Int> { c in
    outerRuns += 1
    return c[inner] * 2
  }

  #expect(cogs.peek(inner) == 4)
  #expect(innerRuns == 1)
  #expect(outerRuns == 0)

  // Reading the outer one now runs it, and does not run the inner one again.
  #expect(cogs.peek(outer) == 8)
  #expect(innerRuns == 1)
  #expect(outerRuns == 1)
}

@MainActor
@Test func `DECL-09 a context that never sees a declaration runs nothing`() {
  // The declaration is one thing; the running of it is per context. A
  // second context has run nothing until it is asked.
  var runs = 0

  let first = Cogs.forTesting()
  let second = Cogs.forTesting()
  let source = Cog<Int>.Manual { 1 }
  let doubled = Cog<Int> { c in
    runs += 1
    return c[source] * 2
  }

  #expect(first.peek(doubled) == 2)
  #expect(runs == 1)

  _ = second.peek(source)
  #expect(runs == 1)
}
