import CogTesting
import Testing

@testable import Cog

// `M1-01b`'s storage layer, asserted directly. These tests green no scenario:
// the behavior a user was promised is in `M1CogtextReadTests.swift`, which
// stays on the public surface. What is checked here is the invariant that
// behavior rests on — one node per descriptor and key, created on first use —
// and there is no public way to observe it yet, because boxes (`M1-02`) and
// writes (`M1-04ab`) are what make per-key and per-context identity visible
// from outside. Until they land, this file is the only thing standing between
// a silent storage bug and the tasks that build on it.
//
// Being implementation tests, they are allowed to reach through `@testable`,
// and they are expected to change when the data-oriented core (`M6`) replaces
// dictionary storage. The scenario tests are not.

// MARK: - Laziness

@MainActor
@Test func `M1NodeStorage creates nothing until a declaration is used`() {
  let cogs = Cogtext.forTesting()
  #expect(cogs.nodes.isEmpty)

  // Declaring allocates a descriptor and touches no context.
  let retryLimit = ManualCog<Int>(3)
  let unused = ManualCog<Int>(0)
  #expect(cogs.nodes.isEmpty)

  _ = cogs.read(retryLimit)

  // The one read made one node, and the declaration nobody read has none.
  #expect(cogs.nodes.count == 1)
  #expect(cogs.nodes[CogNodeIdentity(descriptor: unused.descriptor.identity, key: nil)] == nil)
}

// MARK: - One node per descriptor and key

@MainActor
@Test func `M1NodeStorage reuses one node for one declaration`() {
  let cogs = Cogtext.forTesting()
  let retryLimit = ManualCog<Int>(3)

  let first = cogs.manualNode(for: retryLimit)
  let second = cogs.manualNode(for: retryLimit)

  #expect(first === second)
  #expect(cogs.nodes.count == 1)
}

@MainActor
@Test func `M1NodeStorage resolves a copied ref to the same node`() {
  // Refs are values that get copied and passed around freely; copying one must
  // not be a way to end up with a second piece of state.
  let cogs = Cogtext.forTesting()
  let declared = ManualCog<Int>(3)
  let copied = declared

  #expect(cogs.manualNode(for: declared) === cogs.manualNode(for: copied))
  #expect(cogs.nodes.count == 1)
}

@MainActor
@Test func `M1NodeStorage gives every key of a declaration its own node`() {
  // The seam `box[key]` uses in `M1-02`: one descriptor, one node per key.
  let cogs = Cogtext.forTesting()
  let weather = ManualCog<Int>(0)

  let here = ManualCog(descriptor: weather.descriptor, key: 90210)
  let there = ManualCog(descriptor: weather.descriptor, key: 10001)
  let hereAgain = ManualCog(descriptor: weather.descriptor, key: 90210)

  #expect(cogs.manualNode(for: here) !== cogs.manualNode(for: there))
  #expect(cogs.manualNode(for: here) === cogs.manualNode(for: hereAgain))
  #expect(cogs.nodes.count == 2)
}

@MainActor
@Test func `M1NodeStorage keeps a keyless declaration separate from its keys`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  let keyed = ManualCog(descriptor: source.descriptor, key: 0)

  #expect(cogs.manualNode(for: source) !== cogs.manualNode(for: keyed))
  #expect(cogs.nodes.count == 2)
}

@MainActor
@Test func `M1NodeStorage tells identical declarations apart`() {
  // Same type, same starting value, same label — two declarations, so two
  // nodes. Identity is the descriptor object and nothing else (§2.3).
  let cogs = Cogtext.forTesting()
  let left = ManualCog<Int>(0, name: "twin")
  let right = ManualCog<Int>(0, name: "twin")

  #expect(cogs.manualNode(for: left) !== cogs.manualNode(for: right))
  #expect(cogs.nodes.count == 2)
}

// MARK: - Per context

@MainActor
@Test func `M1NodeStorage gives every context its own nodes`() {
  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()
  let retryLimit = ManualCog<Int>(3)

  let inFirst = first.manualNode(for: retryLimit)
  let inSecond = second.manualNode(for: retryLimit)

  #expect(inFirst !== inSecond)
  #expect(first.nodes.count == 1)
  #expect(second.nodes.count == 1)
}

// MARK: - What a node starts at

@MainActor
@Test func `M1NodeStorage starts a node at its declaration's starting value`() {
  let cogs = Cogtext.forTesting()
  let retryLimit = ManualCog<Int>(3)
  let keyed = ManualCog(descriptor: retryLimit.descriptor, key: 90210)

  #expect(cogs.manualNode(for: retryLimit).currentValue == 3)
  #expect(cogs.manualNode(for: keyed).currentValue == 3)
}

@MainActor
@Test func `M1NodeStorage keeps a node's label and key for diagnostics`() {
  let cogs = Cogtext.forTesting()
  let weather = ManualCog<Int>(0, name: "weather")
  let keyed = ManualCog(descriptor: weather.descriptor, key: 90210)

  let node = cogs.manualNode(for: keyed)

  #expect("\(node.label)" == "weather")
  #expect(node.key == AnyHashable(90210))
  #expect(cogs.manualNode(for: weather).key == nil)
}
