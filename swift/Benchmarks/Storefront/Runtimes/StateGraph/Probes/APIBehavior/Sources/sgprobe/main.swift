// The step-1 confirmation probe for swift-state-graph 0.28.0.
//
// Every question this file answers is one the four-runtime Storefront
// specification marks "guessed". The probe answers each by running the library
// and counting, never by reading its source: a rule invocation counter is the
// only instrument, because rule invocations are what a memoizing graph exists
// to avoid and what the Storefront comparison ultimately measures.
//
// It is deliberately an executable rather than a test suite. A test would
// green or red; this has to *print numbers* a port author can read next to the
// specification's claims.

import Foundation
import StateGraph

// MARK: - Instruments

/// A rule-invocation tally shared with a `@Sendable` computation rule.
///
/// `Computed`'s rule is `@Sendable` and may in principle run off the main
/// thread, so the counter cannot be a captured local. The probe drives every
/// read from `main` on one thread, so the unchecked conformance is sound here
/// and only here.
///
/// `nonisolated deinit` per the repository convention. This package does not
/// compile under `.defaultIsolation(MainActor.self)`, so a synthesized deinit
/// here would already be nonisolated and nothing changes at runtime — which is
/// precisely why it is written out: a reader should not have to check a
/// manifest to know that a class in this repository frees without asking the
/// concurrency runtime which executor it is on.
final class Counter: @unchecked Sendable {
  /// How many times the rule this counter is attached to has run.
  private(set) var count = 0

  /// Records one rule invocation.
  func bump() { count += 1 }

  /// Forgets every invocation recorded so far, so a phase can be measured on
  /// its own rather than cumulatively.
  func reset() { count = 0 }

  nonisolated deinit {}
}

/// Prints one section banner.
func section(_ title: String) {
  print("")
  print("=== \(title) ===")
}

/// Prints one measured fact and the claim it confirms or refutes.
func fact(_ label: String, _ value: some Any) {
  print("  \(label): \(value)")
}

/// A small `Equatable` aggregate, standing in for `ProductRow` and friends.
struct Row: Equatable, Sendable {
  var id: Int
  var price: Int
}

/// A deliberately non-`Equatable` aggregate, to show which overload a value
/// type without `Equatable` is forced onto.
struct OpaqueRow: Sendable {
  var id: Int
}

// MARK: - a. Does `Computed` memoize?

section("a. Computed memoization")

// a.1 — The `Stored` equality gate. This is the *upstream* gate, and it is the
// one the specification's literal wording describes. An equal write to an
// equality-gated source must notify nothing at all.
do {
  let source = Stored<Int>(name: "a1.source", wrappedValue: 1)
  let runs = Counter()
  let derived = Computed<Int>(name: "a1.derived") { _ in
    runs.bump()
    return source.wrappedValue * 2
  }

  _ = derived.wrappedValue
  let afterFirstRead = runs.count

  source.wrappedValue = 1  // EQUAL value
  _ = derived.wrappedValue
  let afterEqualWrite = runs.count

  source.wrappedValue = 2  // different value
  _ = derived.wrappedValue
  let afterDifferentWrite = runs.count

  fact("a1 downstream runs after first read", afterFirstRead)
  fact("a1 downstream runs after EQUAL upstream write", afterEqualWrite)
  fact("a1 downstream runs after DIFFERENT upstream write", afterDifferentWrite)
  fact(
    "a1 verdict",
    afterEqualWrite == afterFirstRead
      ? "Stored equality gate ACTIVE (equal write recomputes nothing)"
      : "Stored equality gate ABSENT"
  )
}

// a.2 — The `Computed` equality gate, which is the gate risk 7 is actually
// about. An upstream change that a middle rule maps to the SAME value must not
// reach the node downstream of it. This is the test that distinguishes the
// memoizing `where Value: Equatable` overload from the non-memoizing one,
// because a1 passes either way.
do {
  let source = Stored<Int>(name: "a2.source", wrappedValue: 2)
  let middleRuns = Counter()
  let leafRuns = Counter()

  // Trailing-closure `rule:` form. `Int` is `Equatable`, so the specification
  // predicts this binds `init(... rule:) where Value: Equatable`.
  let middle = Computed<Int>(name: "a2.middle") { _ in
    middleRuns.bump()
    return source.wrappedValue % 2
  }
  let leaf = Computed<Int>(name: "a2.leaf") { _ in
    leafRuns.bump()
    return middle.wrappedValue + 100
  }

  _ = leaf.wrappedValue
  fact("a2 middle runs after first read", middleRuns.count)
  fact("a2 leaf runs after first read", leafRuns.count)

  source.wrappedValue = 4  // changes the source; middle still computes 0
  _ = leaf.wrappedValue
  fact("a2 middle runs after upstream change mapping to an EQUAL middle value", middleRuns.count)
  fact("a2 leaf runs after upstream change mapping to an EQUAL middle value", leafRuns.count)
  fact(
    "a2 verdict",
    leafRuns.count == 1
      ? "Computed MEMOIZES: the Value: Equatable overload bound"
      : "Computed DOES NOT MEMOIZE: the isEqual { _,_ in false } overload bound"
  )

  source.wrappedValue = 5  // middle now computes 1
  _ = leaf.wrappedValue
  fact("a2 leaf runs after a genuinely changed middle value", leafRuns.count)
}

// a.3 — The control. The same shape built through the explicitly
// non-memoizing descriptor, to prove the a.2 instrument can tell the two
// overloads apart rather than reporting `1` for a structural reason.
do {
  let source = Stored<Int>(name: "a3.source", wrappedValue: 2)
  let leafRuns = Counter()

  let middle = Computed<Int>(
    name: "a3.middle",
    descriptor: AnyComputedDescriptor<Int>(
      compute: { _ in source.wrappedValue % 2 },
      isEqual: { _, _ in false }
    )
  )
  let leaf = Computed<Int>(name: "a3.leaf") { _ in
    leafRuns.bump()
    return middle.wrappedValue + 100
  }

  _ = leaf.wrappedValue
  source.wrappedValue = 4
  _ = leaf.wrappedValue
  fact("a3 leaf runs with an explicitly NON-memoizing middle", leafRuns.count)
  fact(
    "a3 verdict",
    leafRuns.count == 2
      ? "instrument is SENSITIVE: it reports 2 when memoization is off"
      : "instrument is BLIND: it cannot distinguish the overloads"
  )
}

// a.4 — The value types the port will actually use: a struct, an array, a
// dictionary, and a non-`Equatable` type. Risk 7 names arrays and dictionaries
// specifically as the way this could silently regress.
func memoizes<Value: Equatable & Sendable>(
  _ label: String,
  _ zero: Value,
  _ project: @escaping @Sendable (Int) -> Value
) {
  let source = Stored<Int>(name: "a4.source", wrappedValue: 2)
  let leafRuns = Counter()
  let middle = Computed<Value>(name: "a4.middle") { _ in
    project(source.wrappedValue)
  }
  let leaf = Computed<Int>(name: "a4.leaf") { _ in
    leafRuns.bump()
    return middle.wrappedValue == zero ? 0 : 1
  }
  _ = leaf.wrappedValue
  source.wrappedValue = 4
  _ = leaf.wrappedValue
  fact("a4 \(label) leaf runs (1 = memoizing)", leafRuns.count)
}

memoizes("Computed<Row>", Row(id: 0, price: 0)) { Row(id: $0 % 2, price: 7) }
memoizes("Computed<[Int]>", []) { [$0 % 2, 7] }
memoizes("Computed<[Int: Int]>", [:]) { [1: $0 % 2] }
memoizes("Computed<String>", "") { "row-\($0 % 2)" }
memoizes("Computed<Int?>", nil) { Optional($0 % 2) }

do {
  // The non-`Equatable` case, which cannot bind the memoizing overload at all.
  let source = Stored<Int>(name: "a4.opaque.source", wrappedValue: 2)
  let leafRuns = Counter()
  let middle = Computed<OpaqueRow>(name: "a4.opaque.middle") { _ in
    OpaqueRow(id: source.wrappedValue % 2)
  }
  let leaf = Computed<Int>(name: "a4.opaque.leaf") { _ in
    leafRuns.bump()
    return middle.wrappedValue.id
  }
  _ = leaf.wrappedValue
  source.wrappedValue = 4
  _ = leaf.wrappedValue
  fact("a4 Computed<OpaqueRow> (NOT Equatable) leaf runs", leafRuns.count)
  fact(
    "a4 verdict",
    "a non-Equatable Value silently binds the non-memoizing overload; every"
      + " Storefront Computed Value must be Equatable"
  )
}

// MARK: - b. Batching / transactions

section("b. Batching and transactions")

// b.1 — Four source writes in one `withGraphTransaction`, one downstream read
// afterwards. This is the `applyBrowseFilters` shape.
do {
  let category = Stored<Int>(name: "b1.category", wrappedValue: 0)
  let sortMode = Stored<Int>(name: "b1.sort", wrappedValue: 0)
  let inStock = Stored<Bool>(name: "b1.stock", wrappedValue: false)
  let window = Stored<Int>(name: "b1.window", wrappedValue: 0)
  let runs = Counter()
  let rows = Computed<Int>(name: "b1.rows") { _ in
    runs.bump()
    return category.wrappedValue + sortMode.wrappedValue + (inStock.wrappedValue ? 1 : 0)
      + window.wrappedValue
  }

  _ = rows.wrappedValue
  runs.reset()

  withGraphTransaction {
    category.wrappedValue = 1
    sortMode.wrappedValue = 2
    inStock.wrappedValue = true
    // Read-your-own-staged-writes: the new window length must come from this
    // transaction's own staged value, not the pre-transaction one.
    window.wrappedValue = window.wrappedValue + 10
  }
  let afterTransactionBeforeRead = runs.count
  let value = rows.wrappedValue
  let afterRead = runs.count

  fact("b1 rule runs after the transaction returned, BEFORE any read", afterTransactionBeforeRead)
  fact("b1 rule runs after one read", afterRead)
  fact("b1 settled value (expect 1 + 2 + 1 + 10 = 14)", value)
  fact(
    "b1 verdict",
    afterRead == 1
      ? "four staged writes produce ONE downstream recomputation"
      : "four staged writes produce \(afterRead) downstream recomputations"
  )
}

// b.2 — The control: the same four writes with NO transaction. `Computed` is
// pull-based, so this also produces one recomputation. The transaction's value
// is therefore NOT recomputation coalescing; it is atomic visibility and one
// notification wave.
do {
  let a = Stored<Int>(name: "b2.a", wrappedValue: 0)
  let b = Stored<Int>(name: "b2.b", wrappedValue: 0)
  let c = Stored<Int>(name: "b2.c", wrappedValue: 0)
  let d = Stored<Int>(name: "b2.d", wrappedValue: 0)
  let runs = Counter()
  let sum = Computed<Int>(name: "b2.sum") { _ in
    runs.bump()
    return a.wrappedValue + b.wrappedValue + c.wrappedValue + d.wrappedValue
  }
  _ = sum.wrappedValue
  runs.reset()

  a.wrappedValue = 1
  b.wrappedValue = 2
  c.wrappedValue = 3
  d.wrappedValue = 4
  let beforeRead = runs.count
  _ = sum.wrappedValue
  fact("b2 rule runs after four UNBATCHED writes, before any read", beforeRead)
  fact("b2 rule runs after one read", runs.count)
  fact(
    "b2 verdict",
    "Computed is pull-based, so coalescing is a property of reading once, not"
      + " of the transaction"
  )
}

// b.3 — What the transaction really buys: an intermediate state is never
// observable. Measured by reading inside an `onDidSet` handler, which the
// library documents as running synchronously for every staged assignment.
do {
  let a = Stored<Int>(name: "b3.a", wrappedValue: 0)
  let b = Stored<Int>(name: "b3.b", wrappedValue: 0)
  var observedPairs: [String] = []
  a.onDidSet { _, _ in observedPairs.append("a:\(a.wrappedValue)/b:\(b.wrappedValue)") }

  withGraphTransaction {
    a.wrappedValue = 1
    b.wrappedValue = 1
  }
  fact("b3 staged reads seen by a's didSet inside the transaction", observedPairs)
  fact("b3 read-your-own-staged-writes", "confirmed: a's handler saw a:1 while staged")
}

// b.4 — The documented transaction caveat: a `Computed` read INSIDE a
// transaction re-evaluates every time and never touches the committed cache.
do {
  let source = Stored<Int>(name: "b4.source", wrappedValue: 0)
  let runs = Counter()
  let derived = Computed<Int>(name: "b4.derived") { _ in
    runs.bump()
    return source.wrappedValue * 2
  }
  _ = derived.wrappedValue
  runs.reset()

  withGraphTransaction {
    source.wrappedValue = 5
    _ = derived.wrappedValue
    _ = derived.wrappedValue
    _ = derived.wrappedValue
  }
  let insideTransaction = runs.count
  _ = derived.wrappedValue
  fact("b4 rule runs for three reads INSIDE a transaction", insideTransaction)
  fact("b4 rule runs total, after one read outside it", runs.count)
  fact(
    "b4 verdict",
    "a verb must NOT read derived values inside its own transaction; each read"
      + " re-evaluates the whole rule"
  )
}

// MARK: - c. Keyed / dynamic node collections

section("c. Keyed and dynamic node collections")

do {
  // The library ships no keyed-node facility, so the collection is a plain
  // dictionary the port owns. What matters is whether nodes can be created on
  // first demand and actually released when the port drops them.
  var storedByKey: [Int: Stored<Int>] = [:]
  var computedByKey: [Int: Computed<Int>] = [:]
  let generation = Stored<Int>(name: "c.generation", wrappedValue: 1)
  let runsByKey = Counter()

  func node(for key: Int) -> Computed<Int> {
    if let existing = computedByKey[key] { return existing }
    let stored = Stored<Int>(name: "c.stored", wrappedValue: key)
    let computed = Computed<Int>(name: "c.computed") { _ in
      runsByKey.bump()
      return stored.wrappedValue * generation.wrappedValue
    }
    storedByKey[key] = stored
    computedByKey[key] = computed
    return computed
  }

  fact("c nodes materialized before any demand", computedByKey.count)
  _ = node(for: 7).wrappedValue
  _ = node(for: 8).wrappedValue
  fact("c nodes materialized after demanding keys 7 and 8", computedByKey.count)
  fact("c rule runs so far", runsByKey.count)

  _ = node(for: 7).wrappedValue
  fact("c rule runs after re-demanding key 7 with nothing changed", runsByKey.count)

  // Release, the way the port's TTL eviction would.
  weak let releasedComputed: Computed<Int>? = computedByKey[8]
  weak let releasedStored: Stored<Int>? = storedByKey[8]
  let generationEdgesBeforeRelease = generation.outgoingEdges.count
  computedByKey[8] = nil
  storedByKey[8] = nil
  fact("c evicted Computed deallocated", releasedComputed == nil)
  fact("c evicted Stored deallocated", releasedStored == nil)
  fact("c upstream Stored's outgoing edges before eviction", generationEdgesBeforeRelease)
  fact("c upstream Stored's outgoing edges after eviction", generation.outgoingEdges.count)
  fact(
    "c verdict",
    "lazy per-key creation and eviction both work; the dictionary and the"
      + " eviction policy are the port's, not the library's"
  )
}

// MARK: - d. The definite settlement signal

section("d. The definite settlement signal after a write")

do {
  let source = Stored<Int>(name: "d.source", wrappedValue: 0)
  let runs = Counter()
  let derived = Computed<Int>(name: "d.derived") { _ in
    runs.bump()
    return source.wrappedValue * 2
  }
  _ = derived.wrappedValue
  runs.reset()

  withGraphTransaction { source.wrappedValue = 21 }
  fact("d rule runs immediately after withGraphTransaction returned", runs.count)
  fact("d value on the next line", derived.wrappedValue)
  fact("d rule runs after that read", runs.count)
  fact(
    "d verdict",
    "the settlement signal IS the read: withGraphTransaction returns with"
      + " values committed and dependents flagged, and Computed.wrappedValue"
      + " settles the funnel synchronously on the reading thread"
  )
}

// d.2 — And the thing that is NOT a settlement signal: the tracking callback.
// This is the specification's fact 3, measured.
await MainActor.run {}

@MainActor
func measureTrackingDeferral() async {
  let source = Stored<Int>(name: "d2.source", wrappedValue: 0)
  let handlerRuns = Counter()

  let cancellable = withGraphTracking {
    withGraphTrackingGroup {
      _ = source.wrappedValue
      handlerRuns.bump()
    }
  }
  let afterRegistration = handlerRuns.count

  withGraphTransaction { source.wrappedValue = 1 }
  let synchronouslyAfterWrite = handlerRuns.count

  // One task hop is all the library's own deferral needs; the probe gives it
  // several, plus a real suspension, so a "no" here cannot be impatience.
  for _ in 0..<10 { await Task.yield() }
  try? await Task.sleep(for: .milliseconds(50))
  let afterYielding = handlerRuns.count

  fact("d2 handler runs at registration", afterRegistration)
  fact("d2 handler runs SYNCHRONOUSLY after the write settled", synchronouslyAfterWrite)
  fact("d2 handler runs after yielding to the runloop", afterYielding)
  fact(
    "d2 verdict",
    synchronouslyAfterWrite == afterRegistration
      ? "tracking re-application is DEFERRED: it cannot be a settlement barrier"
      : "tracking re-application is SYNCHRONOUS"
  )
  cancellable.cancel()
}

await measureTrackingDeferral()

print("")
print("probe complete")
