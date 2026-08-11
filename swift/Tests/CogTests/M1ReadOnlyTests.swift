import Cog
import CogTesting
import Testing

// The one scenario `M1-03` greens through tests; DECL-06, the other half of
// `.readOnly`, is a compile-fail fixture
// (`swift/CompileFail/Declaring/ReadOnlyWriteRejected.swift`) because "the
// compiler says no" is not something a running test can observe.
//
// Public `Cog` API and the `CogTesting` product only — no `@testable`, no
// descriptors, no node storage (scenarios.md constraint 3). That matters more
// here than almost anywhere: the claim is that a projection is the *same* ref
// for the same state, and the honest way to show it is that reads through the
// two refs cannot be told apart, not that they happen to compute the same
// storage identity today.
//
// Keyed cases prove sameness with a reference-typed value rather than with a
// keyed write, exactly as `M1ManualCogBoxTests.swift` does: keyed staging is
// `M1-04b`'s scenario (TURN-14), and this slice must not lean on behavior that
// has not landed. The keyless cases do write, because keyless staging is
// already `M1-04ab`'s settled surface, and "always gives the same value as the
// source" is worth showing across a real change of value.
//
// Refs are declared inside each test rather than at file scope, and every test
// states `@MainActor`, for the reason the sibling suites give: a file-scope
// `let` would say different things in the MainActor and nonisolated legs of the
// matrix (§7).

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
@Test func `DECL-05 a read-only ref reads what its source reads`() {
  let cogs = Cogtext.forTesting()

  let retryLimitSource = ManualCog<Int>(3)
  let greetingSource = ManualCog<String>("hello")
  let currentZipSource = ManualCog<ZipCode?>(nil)

  let retryLimit = retryLimitSource.readOnly
  let greeting = greetingSource.readOnly
  let currentZip = currentZipSource.readOnly

  #expect(cogs.read(retryLimit) == cogs.read(retryLimitSource))
  #expect(cogs.read(greeting) == cogs.read(greetingSource))
  #expect(cogs.read(currentZip) == cogs.read(currentZipSource))

  #expect(cogs.read(retryLimit) == 3)
  #expect(cogs.read(greeting) == "hello")
  #expect(cogs.read(currentZip) == nil)
}

@MainActor
@Test func `DECL-05 a write through the source is what the read-only ref reads`() {
  // The point of the projection: the owning file writes the source, and
  // everyone holding the published ref sees it. No copy to refresh, no second
  // node to keep in step.
  let cogs = Cogtext.forTesting()

  let countSource = ManualCog<Int>(0)
  let count = countSource.readOnly

  cogs.commit { w in
    w[countSource] = 7
  }

  #expect(cogs.read(count) == 7)
  #expect(cogs.read(count) == cogs.read(countSource))
}

@MainActor
@Test func `DECL-05 the read-only ref agrees with its source after every write`() {
  // "Always," not "once": the two refs stay indistinguishable across a run of
  // turns, whichever of them is read first.
  let cogs = Cogtext.forTesting()

  let countSource = ManualCog<Int>(0)
  let count = countSource.readOnly

  for value in 1...10 {
    cogs.commit { w in
      w[countSource] = value
    }

    #expect(cogs.read(count) == value)
    #expect(cogs.read(count) == cogs.read(countSource))
  }
}

@MainActor
@Test func `DECL-05 reading the projection first does not create a second piece of state`() {
  // A read is what makes a node appear (§2.3), so the projection reading first
  // is the case where a wrong implementation would quietly make its own node.
  // A reference-typed value makes that visible without any write: one node
  // means one object.
  let cogs = Cogtext.forTesting()

  let ledgerSource = ManualCog<Ledger>(Ledger())
  let ledger = ledgerSource.readOnly

  cogs.read(ledger).entries.append("published")

  #expect(cogs.read(ledgerSource).entries == ["published"])
  #expect(cogs.read(ledger) === cogs.read(ledgerSource))
}

@MainActor
@Test func `DECL-05 projecting a source twice names one piece of state`() {
  // Projecting is not declaring. `.readOnly` builds a ref, the way `box[key]`
  // does, so asking for it in two places is not a way to end up with two
  // pieces of state.
  let cogs = Cogtext.forTesting()

  let ledgerSource = ManualCog<Ledger>(Ledger())

  #expect(cogs.read(ledgerSource.readOnly) === cogs.read(ledgerSource.readOnly))
  #expect(cogs.read(ledgerSource.readOnly) === cogs.read(ledgerSource))
}

@MainActor
@Test func `DECL-05 each context answers its projection with its own state`() {
  // The projection is a ref, and a ref is the same ref everywhere; the state
  // is per context (§2.3). A test runtime reading a published ref reads its
  // own world, not the one next door.
  let countSource = ManualCog<Int>(0)
  let count = countSource.readOnly

  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()

  first.commit { w in
    w[countSource] = 7
  }

  #expect(first.read(count) == 7)
  #expect(second.read(count) == 0)
}

// MARK: - DECL-05, keyed

@MainActor
@Test func `DECL-05 a read-only box key reads what that key of the source reads`() {
  let cogs = Cogtext.forTesting()

  let retryLimitSource = ManualCogBox<Int, String>(3)
  let retryLimit = retryLimitSource.readOnly

  #expect(cogs.read(retryLimit["upload"]) == cogs.read(retryLimitSource["upload"]))
  #expect(cogs.read(retryLimit["upload"]) == 3)
  #expect(cogs.read(retryLimit["download"]) == 3)
}

@MainActor
@Test func `DECL-05 a projected box still starts each key from its own closure`() {
  // Projecting changes who may write, and nothing else: the declaration behind
  // the projection is the same declaration, so the starting-value closure runs
  // for a key reached through the projection exactly as it would for the
  // source.
  let cogs = Cogtext.forTesting()

  let greetingSource = ManualCogBox<String, ZipCode> { zip in "hello, \(zip.digits)" }
  let greeting = greetingSource.readOnly

  #expect(cogs.read(greeting[ZipCode(digits: "90210")]) == "hello, 90210")
  #expect(cogs.read(greeting[ZipCode(digits: "10001")]) == "hello, 10001")
}

@MainActor
@Test func `DECL-05 a projected key names the same state as that key of the source`() {
  let cogs = Cogtext.forTesting()

  let ledgersSource = ManualCogBox<Ledger, ZipCode> { _ in Ledger() }
  let ledgers = ledgersSource.readOnly
  let here = ZipCode(digits: "90210")

  cogs.read(ledgers[here]).entries.append("published")

  #expect(cogs.read(ledgersSource[here]).entries == ["published"])
  #expect(cogs.read(ledgers[here]) === cogs.read(ledgersSource[here]))
}

@MainActor
@Test func `DECL-05 keys stay separate through a read-only box`() {
  // A projection is not a flattening. Each key of the projected box is still
  // its own state, and still the same state as that key of the source.
  let cogs = Cogtext.forTesting()

  let ledgersSource = ManualCogBox<Ledger, ZipCode> { _ in Ledger() }
  let ledgers = ledgersSource.readOnly
  let here = ZipCode(digits: "90210")
  let there = ZipCode(digits: "10001")

  cogs.read(ledgers[here]).entries.append("here")

  #expect(cogs.read(ledgers[there]).entries == [])
  #expect(cogs.read(ledgers[here]) !== cogs.read(ledgers[there]))
  #expect(cogs.read(ledgers[there]) === cogs.read(ledgersSource[there]))
}

@MainActor
@Test func `DECL-05 equal keys name one piece of state through the projection`() {
  // Identity is descriptor plus key, and the projection changes neither, so
  // "the same key" still means equal rather than identical (§3.1).
  let cogs = Cogtext.forTesting()

  let ledgers = ManualCogBox<Ledger, ZipCode> { _ in Ledger() }.readOnly

  let here = ZipCode(digits: "90210")
  let hereAgain = ZipCode(digits: "902" + "10")

  #expect(cogs.read(ledgers[here]) === cogs.read(ledgers[hereAgain]))
}
