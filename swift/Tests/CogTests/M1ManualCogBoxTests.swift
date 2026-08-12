import Cog
import CogTesting
import Testing

// The three scenarios `M1-02` greens. Like `M1CogtextReadTests.swift`, this
// file stays on the public `Cog` API and the `CogTesting` product — no
// `@testable`, no descriptors, no state storage — because COUNT-09 through
// COUNT-11 require this suite to keep passing unchanged when the value-reference layout
// and the core underneath it are replaced (scenarios.md constraint 3). The
// storage invariants boxes rest on are asserted separately, in
// `M1ManualCogBoxInfrastructureTests.swift`, which greens no scenario.
//
// M1-02 first proved keyed identity with a reference-typed value before turns
// existed. M1-04b strengthens DECL-04's write clause in place with a real
// keyed commit, while TURN-14 separately owns the writer read-back behavior.
//
// Value references and boxes are declared inside each test rather than at file scope. A
// `ManualCogBox` is MainActor-isolated, and a file-scope `let` would say
// different things in the MainActor and nonisolated legs of the matrix; a
// local says the same thing in all four. Every test states `@MainActor` for
// the same reason (§7).

// MARK: - Test values

/// A value with an identity and something to change about it.
///
/// Boxes exist to give each key its own state. A reference type makes "its
/// own" observable without depending on keyed turn behavior: two keys either
/// hand back the same object or they do not.
private final class Ledger {
  var entries: [String] = []
}

/// What a starting-value closure was asked for, in order.
private final class KeyLog {
  var keys: [Int] = []
}

/// A key type that is not a `String` or an `Int`, to keep the tests honest
/// about `Key: Hashable` rather than about the two easy cases.
private struct ZipCode: Hashable {
  let digits: String
}

// MARK: - DECL-02

@MainActor
@Test func `DECL-02 every key of a box starts at the box's starting value`() {
  let cogs = Cogtext.forTesting()

  let retryLimit = ManualCogBox<Int, String>(3)

  #expect(cogs.read(retryLimit["upload"]) == 3)
  #expect(cogs.read(retryLimit["download"]) == 3)
  #expect(cogs.read(retryLimit["sync"]) == 3)
}

@MainActor
@Test func `DECL-02 a box needs no list of its keys`() {
  // Nothing registers a key, and no key is more declared than any other: the
  // hundredth key a program thinks of works exactly as well as the first.
  let cogs = Cogtext.forTesting()

  let unreadCount = ManualCogBox<Int, Int>(0)

  for conversation in 0..<100 {
    #expect(cogs.read(unreadCount[conversation]) == 0)
  }
}

@MainActor
@Test func `DECL-02 a key keeps returning its starting value until something writes`() {
  // Reading is not a one-time unwrapping of the declaration: with nothing
  // written, the tenth read of a key says what the first read said, and
  // reading one key does not disturb another.
  let cogs = Cogtext.forTesting()

  let weatherReport = ManualCogBox<String?, ZipCode>(nil)
  let here = ZipCode(digits: "90210")
  let there = ZipCode(digits: "10001")

  for _ in 0..<10 {
    #expect(cogs.read(weatherReport[here]) == nil)
    #expect(cogs.read(weatherReport[there]) == nil)
  }
}

@MainActor
@Test func `DECL-02 a key of one box is not a key of another`() {
  // The key is half of the identity; the declaration is the other half. Two
  // boxes that share a key type and differ only in what they start at keep
  // their own values for the same key (§3.1).
  let cogs = Cogtext.forTesting()

  let attempts = ManualCogBox<Int, String>(0)
  let ceiling = ManualCogBox<Int, String>(5)

  #expect(cogs.read(attempts["upload"]) == 0)
  #expect(cogs.read(ceiling["upload"]) == 5)
}

@MainActor
@Test func `DECL-02 a box declares state without creating any`() {
  // A declaration is a name (§2.3). Declaring a box for a key space of
  // millions costs one declaration, and a context that is never asked for a
  // key still answers every key correctly when it finally is.
  let unreadCount = ManualCogBox<Int, Int>(0)

  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()

  #expect(first.read(unreadCount[7]) == 0)
  #expect(second.read(unreadCount[7]) == 0)
}

// MARK: - DECL-03

@MainActor
@Test func `DECL-03 each key starts at what the closure returns for that key`() {
  let cogs = Cogtext.forTesting()

  let doubled = ManualCogBox<Int, Int> { key in key * 2 }

  #expect(cogs.read(doubled[5]) == 10)
  #expect(cogs.read(doubled[6]) == 12)
  #expect(cogs.read(doubled[0]) == 0)
}

@MainActor
@Test func `DECL-03 the closure receives the whole key`() {
  // Not a hash, not an index — the key itself, in its own type, so a starting
  // value can be built out of whatever the key means.
  let cogs = Cogtext.forTesting()

  let greeting = ManualCogBox<String, ZipCode> { zip in "hello, \(zip.digits)" }

  #expect(cogs.read(greeting[ZipCode(digits: "90210")]) == "hello, 90210")
  #expect(cogs.read(greeting[ZipCode(digits: "10001")]) == "hello, 10001")
}

@MainActor
@Test func `DECL-03 the closure gives each key its own starting value`() {
  // The difference the closure form exists for: a constant hands every key one
  // value, so a reference-typed constant would hand every key one *object*,
  // while the closure runs per key and each key starts at its own.
  let cogs = Cogtext.forTesting()

  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  #expect(cogs.read(ledgers[5]) !== cogs.read(ledgers[6]))
}

@MainActor
@Test func `DECL-03 a starting value is a starting value, not a computation`() {
  // A key's value is settled once, when that key's state first appears, and
  // held from then on. Reading a key again does not ask the closure again —
  // which is what makes it a source rather than a derived cog, and is why a
  // later write to a key is permanent.
  let cogs = Cogtext.forTesting()

  let asked = KeyLog()
  let doubled = ManualCogBox<Int, Int> { key in
    asked.keys.append(key)
    return key * 2
  }

  #expect(cogs.read(doubled[5]) == 10)
  #expect(cogs.read(doubled[5]) == 10)
  #expect(cogs.read(doubled[5]) == 10)
  #expect(asked.keys == [5])

  #expect(cogs.read(doubled[6]) == 12)
  #expect(asked.keys == [5, 6])
}

@MainActor
@Test func `DECL-03 every context starts its own keys from the closure`() {
  // A test or preview runtime is its own world (§2.3): the same key in a
  // second context is a second piece of state, so it starts fresh from the
  // declaration rather than inheriting anything from the first.
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()

  #expect(first.read(ledgers[5]) !== second.read(ledgers[5]))
}

// MARK: - DECL-04

/// One "place" that builds `box[5]` and changes what it finds there.
@MainActor
private func recordAnUpload(in cogs: Cogtext, using ledgers: ManualCogBox<Ledger, Int>) {
  cogs.read(ledgers[5]).entries.append("upload")
}

/// Another "place" that builds `box[5]` for itself, knowing nothing about the
/// first.
@MainActor
private func entriesForFive(in cogs: Cogtext, using ledgers: ManualCogBox<Ledger, Int>) -> [String]
{
  cogs.read(ledgers[5]).entries
}

@MainActor
@Test func `DECL-04 value references built in two places name one piece of state`() {
  let cogs = Cogtext.forTesting()
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  recordAnUpload(in: cogs, using: ledgers)

  #expect(entriesForFive(in: cogs, using: ledgers) == ["upload"])

  let writtenElsewhere = Ledger()
  writtenElsewhere.entries.append("replacement")
  let firstValueReference = ledgers[5]
  let secondValueReference = ledgers[2 + 3]

  cogs.commit { w in w[firstValueReference] = writtenElsewhere }

  #expect(cogs.read(secondValueReference) === writtenElsewhere)
  #expect(cogs.read(secondValueReference).entries == ["replacement"])
  #expect(cogs.read(ledgers[6]).entries.isEmpty)
}

@MainActor
@Test func `DECL-04 a different key is a different piece of state`() {
  let cogs = Cogtext.forTesting()
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  recordAnUpload(in: cogs, using: ledgers)

  #expect(cogs.read(ledgers[6]).entries.isEmpty)
  #expect(cogs.read(ledgers[5]) !== cogs.read(ledgers[6]))
}

@MainActor
@Test func `DECL-04 building the same key again reaches the same state`() {
  // Value references are values built at the point of use, not handles to keep. Building
  // one twice — or a hundred times, from a key computed a different way each
  // time — is not a way to end up with a second piece of state.
  let cogs = Cogtext.forTesting()
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  let fromALiteral = cogs.read(ledgers[5])
  let fromArithmetic = cogs.read(ledgers[2 + 3])
  let fromACount = cogs.read(ledgers["hello".count])

  #expect(fromALiteral === fromArithmetic)
  #expect(fromALiteral === fromACount)
}

@MainActor
@Test func `DECL-04 equal keys of a Hashable type name one piece of state`() {
  // Identity is descriptor plus key, and "the same key" means equal, not
  // identical: two separately built `ZipCode` values that compare equal name
  // one state (§3.1).
  let cogs = Cogtext.forTesting()
  let ledgers = ManualCogBox<Ledger, ZipCode> { _ in Ledger() }

  let here = ZipCode(digits: "90210")
  let hereAgain = ZipCode(digits: "902" + "10")
  let there = ZipCode(digits: "10001")

  #expect(cogs.read(ledgers[here]) === cogs.read(ledgers[hereAgain]))
  #expect(cogs.read(ledgers[here]) !== cogs.read(ledgers[there]))
}

@MainActor
@Test func `DECL-04 one key is one piece of state per context, not per process`() {
  // The value reference is the same value reference in both contexts; the
  // state is not the same state.
  // This is the rule that lets tests run in parallel and previews coexist
  // (§2.3).
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()

  recordAnUpload(in: first, using: ledgers)

  #expect(entriesForFive(in: first, using: ledgers) == ["upload"])
  #expect(entriesForFive(in: second, using: ledgers) == [])
}
