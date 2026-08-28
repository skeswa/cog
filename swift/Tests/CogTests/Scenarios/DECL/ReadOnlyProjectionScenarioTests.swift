import Cog
import CogTesting
import Testing

// Runtime tests prove that a projection and its source read one state. The
// compile-fail fixture proves the projection cannot be written.

// MARK: - Test values

/// A value with an identity, so that "the same state" can be shown as "the
/// same object" without depending on how writes work.
private final class Ledger {
  var entries: [String] = []
}

/// A key type that is neither a `String` nor an `Int`.
private struct ZipCode: Hashable {
  let digits: String
}

// MARK: - DECL-05, keyless

@MainActor
@Test func `DECL-05 the read-only value reference agrees with its source after every write`() {
  // "Always," not "once": the two value references agree before any write and
  // stay indistinguishable across a run of turns, whichever of them is read
  // first. The point of the projection: the owning file writes the source, and
  // everyone holding the published value reference sees it. No copy to
  // refresh, no second state to keep in step.
  let cogs = Cogs.forTesting()

  let countSource = Cog<Int>.Manual { 0 }
  let count = countSource.readOnly

  #expect(cogs.peek(count) == 0)
  #expect(cogs.peek(count) == cogs.peek(countSource))

  for value in 1...10 {
    cogs.turn { c in
      c[countSource] = value
    }

    #expect(cogs.peek(count) == value)
    #expect(cogs.peek(count) == cogs.peek(countSource))
  }
}

@MainActor
@Test func `DECL-05 reading the projection first does not create a second piece of state`() {
  // A read is what makes a state appear, so the projection reading first
  // is the case where a wrong implementation would quietly make its own state.
  // A reference-typed value makes that visible without any write: one state
  // means one object.
  let cogs = Cogs.forTesting()

  let ledgerSource = Cog<Ledger>.Manual { Ledger() }
  let ledger = ledgerSource.readOnly

  cogs.peek(ledger).entries.append("published")

  #expect(cogs.peek(ledgerSource).entries == ["published"])
  #expect(cogs.peek(ledger) === cogs.peek(ledgerSource))
}

@MainActor
@Test func `DECL-05 projecting a source twice names one piece of state`() {
  // Projecting is not declaring. `.readOnly` builds a value reference, the way `box[key]`
  // does, so asking for it in two places is not a way to end up with two
  // pieces of state.
  let cogs = Cogs.forTesting()

  let ledgerSource = Cog<Ledger>.Manual { Ledger() }

  #expect(cogs.peek(ledgerSource.readOnly) === cogs.peek(ledgerSource.readOnly))
  #expect(cogs.peek(ledgerSource.readOnly) === cogs.peek(ledgerSource))
}

@MainActor
@Test func `DECL-05 each context answers its projection with its own state`() {
  // The projection is a value reference, and a value reference is the same
  // value reference everywhere; the state is per context. A test
  // runtime reading a published value reference reads its own world, not the
  // one next door.
  let countSource = Cog<Int>.Manual { 0 }
  let count = countSource.readOnly

  let first = Cogs.forTesting()
  let second = Cogs.forTesting()

  first.turn { c in
    c[countSource] = 7
  }

  #expect(first.peek(count) == 7)
  #expect(second.peek(count) == 0)
}

@MainActor
@Test func `DECL-05 watching the projection is watching the source`() {
  // A read-only value reference names the same state its source does, so a
  // watch registered on it wakes for the source's writes with true old-new
  // pairs. This is the projection's whole point at the reactive surface: the
  // owning file writes the source, and a watcher of the published value
  // reference follows along.
  let (cogs, m) = Cogs.forTestingWithController()
  let countSource = Cog<Int>.Manual { 1 }
  let count = countSource.readOnly
  var deliveries: [String] = []

  m.watch(count, initial: .skip) { old, new in
    deliveries.append("\(old)->\(new)")
  }

  cogs.turn { c in c[countSource] = 2 }

  #expect(deliveries == ["1->2"])
}

// MARK: - DECL-05, keyed

@MainActor
@Test func `DECL-05 a read-only box key reads what that key of the source reads`() {
  let cogs = Cogs.forTesting()

  let retryLimitSource = CogBox<Int, String>.Manual { 3 }
  let retryLimit = retryLimitSource.readOnly

  #expect(cogs.peek(retryLimit["upload"]) == cogs.peek(retryLimitSource["upload"]))
  #expect(cogs.peek(retryLimit["upload"]) == 3)
  #expect(cogs.peek(retryLimit["download"]) == 3)
}

@MainActor
@Test func `DECL-05 a projected box still starts each key from its own closure`() {
  // A projection changes only who may write. It keeps the source declaration,
  // so each key uses the same starting-value closure through either reference.
  let cogs = Cogs.forTesting()

  let greetingSource = CogBox<String, ZipCode>.Manual { zip in "hello, \(zip.digits)" }
  let greeting = greetingSource.readOnly

  #expect(cogs.peek(greeting[ZipCode(digits: "90210")]) == "hello, 90210")
  #expect(cogs.peek(greeting[ZipCode(digits: "10001")]) == "hello, 10001")
}

@MainActor
@Test func `DECL-05 a projected key names the same state as that key of the source`() {
  let cogs = Cogs.forTesting()

  let ledgersSource = CogBox<Ledger, ZipCode>.Manual { _ in Ledger() }
  let ledgers = ledgersSource.readOnly
  let here = ZipCode(digits: "90210")

  cogs.peek(ledgers[here]).entries.append("published")

  #expect(cogs.peek(ledgersSource[here]).entries == ["published"])
  #expect(cogs.peek(ledgers[here]) === cogs.peek(ledgersSource[here]))
}

@MainActor
@Test func `DECL-05 keys stay separate through a read-only box`() {
  // A projection is not a flattening. Each key of the projected box is still
  // its own state, and still the same state as that key of the source.
  let cogs = Cogs.forTesting()

  let ledgersSource = CogBox<Ledger, ZipCode>.Manual { _ in Ledger() }
  let ledgers = ledgersSource.readOnly
  let here = ZipCode(digits: "90210")
  let there = ZipCode(digits: "10001")

  cogs.peek(ledgers[here]).entries.append("here")

  #expect(cogs.peek(ledgers[there]).entries == [])
  #expect(cogs.peek(ledgers[here]) !== cogs.peek(ledgers[there]))
  #expect(cogs.peek(ledgers[there]) === cogs.peek(ledgersSource[there]))
}
