import Cog
import CogTesting
import Testing

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
  let cogs = Cogs.forTesting()

  let retryLimit = ManualCogBox<Int, String>(3)

  #expect(cogs.peek(retryLimit["upload"]) == 3)
  #expect(cogs.peek(retryLimit["download"]) == 3)
  #expect(cogs.peek(retryLimit["sync"]) == 3)
}

@MainActor
@Test func `DECL-02 a key keeps returning its starting value until something writes`() {
  // Reading is not a one-time unwrapping of the declaration: with nothing
  // written, the tenth read of a key says what the first read said, and
  // reading one key does not disturb another.
  let cogs = Cogs.forTesting()

  let weatherReport = ManualCogBox<String?, ZipCode>(nil)
  let here = ZipCode(digits: "90210")
  let there = ZipCode(digits: "10001")

  for _ in 0..<10 {
    #expect(cogs.peek(weatherReport[here]) == nil)
    #expect(cogs.peek(weatherReport[there]) == nil)
  }
}

@MainActor
@Test func `DECL-02 a key of one box is not a key of another`() {
  // The key is half of the identity; the declaration is the other half. Two
  // boxes that share a key type and differ only in what they start at keep
  // their own values for the same key.
  let cogs = Cogs.forTesting()

  let attempts = ManualCogBox<Int, String>(0)
  let ceiling = ManualCogBox<Int, String>(5)

  #expect(cogs.peek(attempts["upload"]) == 0)
  #expect(cogs.peek(ceiling["upload"]) == 5)
}

@MainActor
@Test func `DECL-02 a box declares state without creating any`() {
  // A declaration is a name. Declaring a box for a key space of
  // millions costs one declaration, and a context that is never asked for a
  // key still answers every key correctly when it finally is.
  let unreadCount = ManualCogBox<Int, Int>(0)

  let first = Cogs.forTesting()
  let second = Cogs.forTesting()

  #expect(first.peek(unreadCount[7]) == 0)
  #expect(second.peek(unreadCount[7]) == 0)
}

// MARK: - DECL-03

@MainActor
@Test func `DECL-03 each key starts at what the closure returns for that key`() {
  let cogs = Cogs.forTesting()

  let doubled = ManualCogBox<Int, Int> { key in key * 2 }

  #expect(cogs.peek(doubled[5]) == 10)
  #expect(cogs.peek(doubled[6]) == 12)
  #expect(cogs.peek(doubled[0]) == 0)
}

@MainActor
@Test func `DECL-03 the closure receives the whole key`() {
  // Not a hash, not an index — the key itself, in its own type, so a starting
  // value can be built out of whatever the key means.
  let cogs = Cogs.forTesting()

  let greeting = ManualCogBox<String, ZipCode> { zip in "hello, \(zip.digits)" }

  #expect(cogs.peek(greeting[ZipCode(digits: "90210")]) == "hello, 90210")
  #expect(cogs.peek(greeting[ZipCode(digits: "10001")]) == "hello, 10001")
}

@MainActor
@Test func `DECL-03 the closure gives each key its own starting value`() {
  // The difference the closure form exists for: a constant hands every key one
  // value, so a reference-typed constant would hand every key one *object*,
  // while the closure runs per key and each key starts at its own.
  let cogs = Cogs.forTesting()

  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  #expect(cogs.peek(ledgers[5]) !== cogs.peek(ledgers[6]))
}

@MainActor
@Test func `DECL-03 a starting value is a starting value, not a computation`() {
  // A key's value is settled once, when that key's state first appears, and
  // held from then on. Reading a key again does not ask the closure again —
  // which is what makes it a source rather than an automatic cog, and is why a
  // later write to a key is permanent.
  let cogs = Cogs.forTesting()

  let asked = KeyLog()
  let doubled = ManualCogBox<Int, Int> { key in
    asked.keys.append(key)
    return key * 2
  }

  #expect(cogs.peek(doubled[5]) == 10)
  #expect(cogs.peek(doubled[5]) == 10)
  #expect(cogs.peek(doubled[5]) == 10)
  #expect(asked.keys == [5])

  #expect(cogs.peek(doubled[6]) == 12)
  #expect(asked.keys == [5, 6])
}

@MainActor
@Test func `DECL-03 every context starts its own keys from the closure`() {
  // A test or preview runtime is its own world: the same key in a
  // second context is a second piece of state, so it starts fresh from the
  // declaration rather than inheriting anything from the first.
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  let first = Cogs.forTesting()
  let second = Cogs.forTesting()

  #expect(first.peek(ledgers[5]) !== second.peek(ledgers[5]))
}

// MARK: - DECL-04

/// One "place" that builds `box[5]` and changes what it finds there.
@MainActor
private func recordAnUpload(in cogs: Cogs, using ledgers: ManualCogBox<Ledger, Int>) {
  cogs.peek(ledgers[5]).entries.append("upload")
}

/// Another "place" that builds `box[5]` for itself, knowing nothing about the
/// first.
@MainActor
private func entriesForFive(in cogs: Cogs, using ledgers: ManualCogBox<Ledger, Int>) -> [String] {
  cogs.peek(ledgers[5]).entries
}

@MainActor
@Test func `DECL-04 value references built in two places name one piece of state`() {
  let cogs = Cogs.forTesting()
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  recordAnUpload(in: cogs, using: ledgers)

  #expect(entriesForFive(in: cogs, using: ledgers) == ["upload"])

  let writtenElsewhere = Ledger()
  writtenElsewhere.entries.append("replacement")
  let firstValueReference = ledgers[5]
  let secondValueReference = ledgers[2 + 3]

  cogs.turn { c in c[firstValueReference] = writtenElsewhere }

  #expect(cogs.peek(secondValueReference) === writtenElsewhere)
  #expect(cogs.peek(secondValueReference).entries == ["replacement"])
  #expect(cogs.peek(ledgers[6]).entries.isEmpty)
}

@MainActor
@Test func `DECL-04 a different key is a different piece of state`() {
  let cogs = Cogs.forTesting()
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  recordAnUpload(in: cogs, using: ledgers)

  #expect(cogs.peek(ledgers[6]).entries.isEmpty)
  #expect(cogs.peek(ledgers[5]) !== cogs.peek(ledgers[6]))
}

@MainActor
@Test func `DECL-04 building the same key again reaches the same state`() {
  // Value references are values built at the point of use, not handles to keep. Building
  // one twice — or a hundred times, from a key computed a different way each
  // time — is not a way to end up with a second piece of state.
  let cogs = Cogs.forTesting()
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  let fromALiteral = cogs.peek(ledgers[5])
  let fromArithmetic = cogs.peek(ledgers[2 + 3])
  let fromACount = cogs.peek(ledgers["hello".count])

  #expect(fromALiteral === fromArithmetic)
  #expect(fromALiteral === fromACount)
}

@MainActor
@Test func `DECL-04 equal keys of a Hashable type name one piece of state`() {
  // Identity is descriptor plus key, and "the same key" means equal, not
  // identical: two separately built `ZipCode` values that compare equal name
  // one state.
  let cogs = Cogs.forTesting()
  let ledgers = ManualCogBox<Ledger, ZipCode> { _ in Ledger() }

  let here = ZipCode(digits: "90210")
  let hereAgain = ZipCode(digits: "902" + "10")
  let there = ZipCode(digits: "10001")

  #expect(cogs.peek(ledgers[here]) === cogs.peek(ledgers[hereAgain]))
  #expect(cogs.peek(ledgers[here]) !== cogs.peek(ledgers[there]))
}

@MainActor
@Test func `DECL-04 unequal keys with colliding hashes stay separate states`() {
  // "Equal" means `==`, never "hashes alike": a key type whose every value
  // shares one hash still gets one state per distinct key. This is the case
  // that catches an identity-by-hash implementation.
  struct CollidingKey: Hashable {
    let id: Int

    func hash(into hasher: inout Hasher) {
      hasher.combine(0)
    }
  }

  let cogs = Cogs.forTesting()
  let ledgers = ManualCogBox<Ledger, CollidingKey> { _ in Ledger() }

  cogs.peek(ledgers[CollidingKey(id: 1)]).entries.append("first")

  #expect(cogs.peek(ledgers[CollidingKey(id: 2)]).entries == [])
  #expect(cogs.peek(ledgers[CollidingKey(id: 1)]) !== cogs.peek(ledgers[CollidingKey(id: 2)]))
  #expect(cogs.peek(ledgers[CollidingKey(id: 1)]).entries == ["first"])
}

@MainActor
@Test func `DECL-04 one key is one piece of state per context, not per process`() {
  // The value reference is the same value reference in both contexts; the
  // state is not the same state.
  // This is the rule that lets tests run in parallel and previews coexist.
  let ledgers = ManualCogBox<Ledger, Int> { _ in Ledger() }

  let first = Cogs.forTesting()
  let second = Cogs.forTesting()

  recordAnUpload(in: first, using: ledgers)

  #expect(entriesForFive(in: first, using: ledgers) == ["upload"])
  #expect(entriesForFive(in: second, using: ledgers) == [])
}
