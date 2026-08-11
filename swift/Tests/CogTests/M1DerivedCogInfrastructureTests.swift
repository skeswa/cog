import CogTesting
import Testing

@testable import Cog

// `M1-05a`'s machinery, asserted directly. These tests green no scenario: the
// behavior a user was promised is in `M1DerivedCogTests.swift`, which stays on
// the public surface and proves laziness and caching by counting selector runs
// from inside the selector.
//
// What is checked here is the part of the mechanism that behavior rests on and
// that nothing public can see yet: a derived node exists before it has a value,
// the tracking slot names the consumer that is running, and a tracked read
// records the edge §2.4 says it records. Dependency edges are invisible from
// outside until the settle engine (`M1-06aa`) makes them do something, and
// silently failing to capture them would look exactly like working code today
// and like a stale-value bug three tasks from now.
//
// Being implementation tests, they are allowed to reach through `@testable`,
// and they are expected to change when `M1-06aa` adds settle state and when the
// data-oriented core (`M6`) replaces dictionary storage and edge lists. The
// scenario tests are not.

// MARK: - Storage

@MainActor
@Test func `DerivedCogInfrastructure creates nothing until a declaration is used`() {
  let cogs = Cogtext.forTesting()

  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c.get(source) * 2 }
  #expect(cogs.nodes.isEmpty)

  _ = cogs.read(doubled)

  // The derived node and the source node it read, and nothing else.
  #expect(cogs.nodes.count == 2)
}

@MainActor
@Test func `DerivedCogInfrastructure reuses one node for one declaration`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c.get(source) * 2 }

  #expect(cogs.derivedNode(for: doubled) === cogs.derivedNode(for: doubled))
  #expect(cogs.nodes.count == 1)
}

@MainActor
@Test func `DerivedCogInfrastructure tells identical declarations apart`() {
  // Same type, same selector shape, same label — two declarations, so two
  // nodes and two runs. Identity is the descriptor object (§2.3).
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let left = Cog<Int>({ c in c.get(source) }, name: "twin")
  let right = Cog<Int>({ c in c.get(source) }, name: "twin")

  #expect(cogs.derivedNode(for: left) !== cogs.derivedNode(for: right))
  #expect(cogs.nodes.count == 2)
}

@MainActor
@Test func `DerivedCogInfrastructure keeps a node's label for diagnostics`() {
  let cogs = Cogtext.forTesting()
  let named = Cog<Int>({ _ in 1 }, name: "retry budget")
  let unnamed = Cog<Int> { _ in 1 }

  #expect("\(cogs.derivedNode(for: named).label)" == "retry budget")
  #expect("\(cogs.derivedNode(for: unnamed).label)".contains("M1DerivedCogInfrastructureTests"))
  #expect(cogs.derivedNode(for: named).key == nil)
}

// MARK: - Lazy first computation

@MainActor
@Test func `DerivedCogInfrastructure gives a fresh node no value at all`() {
  // Resolving a node is not reading it. The node is filed, and it holds
  // nothing until something asks it for a value.
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c.get(source) * 2 }

  let node = cogs.derivedNode(for: doubled)

  #expect(node.hasComputed == false)
  #expect(node.cachedValue == nil)
  #expect(node.dependencies.isEmpty)

  #expect(node.settledValue(in: cogs) == 2)

  #expect(node.hasComputed)
  #expect(node.cachedValue == 2)
}

@MainActor
@Test func `DerivedCogInfrastructure records a run that produced nil as a run`() {
  // The cache is storage presence, not value optionality: a node that computed
  // `nil` has computed, so the next read must not run the selector again.
  let cogs = Cogtext.forTesting()
  let nothing = Cog<Int?> { _ in nil }

  let node = cogs.derivedNode(for: nothing)
  #expect(node.hasComputed == false)

  #expect(node.settledValue(in: cogs) == nil)

  #expect(node.hasComputed)
}

// MARK: - The tracking slot

@MainActor
@Test func `DerivedCogInfrastructure tracks the node whose selector is running`() {
  let cogs = Cogtext.forTesting()

  var consumerDuringRun: (any CogConsumer)?
  let observing = Cog<Int> { _ in
    consumerDuringRun = cogs.trackedConsumer
    return 1
  }

  #expect(cogs.trackedConsumer == nil)
  _ = cogs.read(observing)

  #expect(consumerDuringRun === cogs.derivedNode(for: observing))
  #expect(cogs.trackedConsumer == nil)
}

@MainActor
@Test func `DerivedCogInfrastructure hands tracking back after a nested run`() {
  // Runs nest whenever a selector reads a derived cog that has not computed.
  // The inner run must own the slot while it runs and give it back afterwards,
  // or the outer selector's later reads would attach to the wrong node.
  let cogs = Cogtext.forTesting()

  var slotDuringInnerRun: (any CogConsumer)?
  var slotAfterInnerRead: (any CogConsumer)?

  let inner = Cog<Int> { _ in
    slotDuringInnerRun = cogs.trackedConsumer
    return 1
  }
  let outer = Cog<Int> { c in
    let value = c.get(inner)
    slotAfterInnerRead = cogs.trackedConsumer
    return value + 1
  }

  #expect(cogs.read(outer) == 2)

  #expect(slotDuringInnerRun === cogs.derivedNode(for: inner))
  #expect(slotAfterInnerRead === cogs.derivedNode(for: outer))
  #expect(cogs.trackedConsumer == nil)
}

// MARK: - Dependency capture

@MainActor
@Test func `DerivedCogInfrastructure records every cog a run read, in read order`() {
  let cogs = Cogtext.forTesting()

  let width = ManualCog<Int>(3)
  let height = ManualCog<Int>(4)
  let area = Cog<Int> { c in c.get(width) * c.get(height) }
  let label = Cog<String> { c in "\(c.get(area)) sq ft, \(c.get(width)) wide" }

  #expect(cogs.read(label) == "12 sq ft, 3 wide")

  let areaNode = cogs.derivedNode(for: area)
  #expect(areaNode.dependencies.count == 2)
  #expect(areaNode.dependencies[0] === cogs.manualNode(for: width))
  #expect(areaNode.dependencies[1] === cogs.manualNode(for: height))

  // A derived parent is recorded the same way a source is: an edge is an edge.
  let labelNode = cogs.derivedNode(for: label)
  #expect(labelNode.dependencies.count == 2)
  #expect(labelNode.dependencies[0] === areaNode)
  #expect(labelNode.dependencies[1] === cogs.manualNode(for: width))
}

@MainActor
@Test func `DerivedCogInfrastructure records nothing for a selector that read nothing`() {
  let cogs = Cogtext.forTesting()
  let constant = Cog<Int> { _ in 7 }

  #expect(cogs.read(constant) == 7)
  #expect(cogs.derivedNode(for: constant).dependencies.isEmpty)
}

@MainActor
@Test func `DerivedCogInfrastructure keeps an untracked read out of the graph`() {
  // `cogs.read` is the untracked one-shot (§2.4). Reading a derived cog that
  // way computes it and records what *it* read, and creates no edge to the
  // caller, because there is no caller in the graph to create one to.
  let cogs = Cogtext.forTesting()

  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c.get(source) * 2 }

  #expect(cogs.read(doubled) == 2)

  #expect(cogs.derivedNode(for: doubled).dependencies.count == 1)
  #expect(cogs.trackedConsumer == nil)
}
