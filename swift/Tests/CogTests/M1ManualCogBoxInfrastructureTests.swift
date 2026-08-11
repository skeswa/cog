import CogTesting
import Testing

@testable import Cog

// `M1-02`'s storage and ref layout, asserted directly. These tests green no
// scenario: what a user of the library was promised is in
// `M1ManualCogBoxTests.swift`, which stays on the public surface. What is
// checked here is what that behavior rests on and what no public API can see
// yet — one descriptor for a whole box, one node per key, and a keyed node
// that knows its own key for diagnostics.
//
// Being implementation tests, they reach through `@testable`, and they are
// expected to change when the ref layout is chosen from benchmarks (perf §4,
// §9) or when the data-oriented core (`M6`) replaces dictionary storage. The
// scenario tests are not.
//
// Every test states `@MainActor` rather than relying on a default, so it says
// the same thing in all four legs of the isolation matrix (§7).

// MARK: - One descriptor per box

@MainActor
@Test func `M1ManualCogBox gives a whole box one descriptor`() {
  // The claim behind "allocation-free `box[key]`" (§2.3, perf §9.1): keys do
  // not each get a declaration of their own, so building a ref has nothing to
  // allocate. It pairs the box's existing descriptor with the key.
  let weather = ManualCogBox<Int, Int>(0)

  let here = weather[90210]
  let there = weather[10001]

  #expect(here.descriptor === weather.descriptor)
  #expect(there.descriptor === weather.descriptor)
  #expect(here.descriptor.identity == there.descriptor.identity)
}

@MainActor
@Test func `M1ManualCogBox puts the key on the ref`() {
  let weather = ManualCogBox<Int, Int>(0)

  #expect(weather[90210].key == AnyHashable(90210))
  #expect(weather[10001].key == AnyHashable(10001))
  #expect(weather[90210].key == weather[90210].key)
  #expect(weather[90210].key != weather[10001].key)
}

@MainActor
@Test func `M1ManualCogBox keeps a keyless declaration and a box apart`() {
  // Two declarations, so two descriptors, even though the keyless ref and the
  // box's refs are the same type.
  let keyless = ManualCog<Int>(0)
  let box = ManualCogBox<Int, Int>(0)

  #expect(keyless.descriptor.identity != box[0].descriptor.identity)
  #expect(keyless.key == nil)
}

@MainActor
@Test func `M1ManualCogBox labels every key with the declaration's label`() {
  // A key is not a declaration, so it does not get a name of its own. The
  // descriptor-and-key path a cycle diagnostic prints (§2.4) is built from the
  // box's label plus the node's key, which is why the node keeps the key.
  let named = ManualCogBox<Int, Int>(0, name: "weather")
  let declarationLine = UInt(#line) + 1
  let unnamed = ManualCogBox<Int, Int>(0)

  #expect("\(named[90210].descriptor.label)" == "weather")
  #expect("\(unnamed[90210].descriptor.label)" == "\(#fileID):\(declarationLine)")
}

// MARK: - One node per key

@MainActor
@Test func `M1ManualCogBox gives every key its own node`() {
  let cogs = Cogtext.forTesting()
  let weather = ManualCogBox<Int, Int>(0)

  #expect(cogs.manualNode(for: weather[90210]) === cogs.manualNode(for: weather[90210]))
  #expect(cogs.manualNode(for: weather[90210]) !== cogs.manualNode(for: weather[10001]))
  #expect(cogs.nodes.count == 2)
}

@MainActor
@Test func `M1ManualCogBox creates a key's node only when it is used`() {
  let cogs = Cogtext.forTesting()

  let weather = ManualCogBox<Int, Int>(0)
  #expect(cogs.nodes.isEmpty)

  // Building refs is not using them. Nothing resolves until a context is
  // asked, which is what makes a ref safe to build inline at a call site.
  let here = weather[90210]
  let there = weather[10001]
  #expect(cogs.nodes.isEmpty)

  _ = cogs.read(here)
  #expect(cogs.nodes.count == 1)
  #expect(cogs.nodes[CogNodeIdentity(descriptor: there.descriptor.identity, key: 10001)] == nil)
}

@MainActor
@Test func `M1ManualCogBox keeps a node's key for diagnostics`() {
  let cogs = Cogtext.forTesting()
  let weather = ManualCogBox<Int, Int>(0, name: "weather")

  let node = cogs.manualNode(for: weather[90210])

  #expect("\(node.label)" == "weather")
  #expect(node.key == AnyHashable(90210))
}

// MARK: - Starting values

@MainActor
@Test func `M1ManualCogBox answers a constant starting value for any key`() {
  let box = ManualCogBox<Int, Int>(3)

  #expect(box.descriptor.startingValue(forKey: 90210) == 3)
  #expect(box.descriptor.startingValue(forKey: 10001) == 3)
}

@MainActor
@Test func `M1ManualCogBox answers a per-key starting value from the closure`() {
  let box = ManualCogBox<Int, Int> { key in key * 2 }

  #expect(box.descriptor.startingValue(forKey: 5) == 10)
  #expect(box.descriptor.startingValue(forKey: 6) == 12)
}

@MainActor
@Test func `M1ManualCogBox keeps a keyless declaration's starting value keyless`() {
  // The descriptor is generic over the value and not over a key, so the
  // keyless case is the `nil` key of the same mechanism rather than a second
  // one.
  let keyless = ManualCog<Int>(7)

  #expect(keyless.descriptor.startingValue(forKey: nil) == 7)
}

// MARK: - Ref cost

@MainActor
@Test func `M1ManualCogBox builds a ref out of two inert words of storage`() {
  // Not a benchmark — PERF-06 measures allocations in the benchmark package at
  // `M5`. This only pins the shape that claim rests on: a ref is a descriptor
  // reference plus the inline `AnyHashable?` the correctness build uses for
  // keys (perf §4), and nothing in `box[key]` builds anything else.
  #expect(
    MemoryLayout<ManualCog<Int>>.size == MemoryLayout<AnyObject>.size
      + MemoryLayout<AnyHashable?>.size)
}
