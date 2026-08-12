import CogTesting
import Testing

@testable import Cog

// Internal checks for state creation, tracking, and dependency edges. Public
// tests prove laziness and caching with selector-owned counters.

// MARK: - Storage

@MainActor
@Test func `DerivedCogInfrastructure creates nothing until a declaration is used`() {
  let cogs = Cogtext.forTesting()

  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c[source] * 2 }
  #expect(cogs.states.isEmpty)

  _ = cogs.peek(doubled)

  // The derived state and the source state it read, and nothing else.
  #expect(cogs.states.count == 2)
}

@MainActor
@Test func `DerivedCogInfrastructure reuses one state for one declaration`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c[source] * 2 }

  #expect(cogs.derivedState(for: doubled) === cogs.derivedState(for: doubled))
  #expect(cogs.states.count == 1)
}

@MainActor
@Test func `DerivedCogInfrastructure tells identical declarations apart`() {
  // Same type, same selector shape, same label — two declarations, so two
  // states and two runs. Identity is the descriptor object.
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let left = Cog<Int>({ c in c[source] }, name: "twin")
  let right = Cog<Int>({ c in c[source] }, name: "twin")

  #expect(cogs.derivedState(for: left) !== cogs.derivedState(for: right))
  #expect(cogs.states.count == 2)
}

@MainActor
@Test func `DerivedCogInfrastructure keeps a state's label for diagnostics`() {
  let cogs = Cogtext.forTesting()
  let named = Cog<Int>({ _ in 1 }, name: "retry budget")
  let unnamed = Cog<Int> { _ in 1 }

  #expect("\(cogs.derivedState(for: named).label)" == "retry budget")
  #expect("\(cogs.derivedState(for: unnamed).label)".contains("DerivedCogInfrastructureTests"))
  #expect(cogs.derivedState(for: named).key == nil)
}

// MARK: - Lazy first computation

@MainActor
@Test func `DerivedCogInfrastructure gives a fresh state no value at all`() {
  // Resolving a state is not reading it. The state is filed, and it holds
  // nothing until something asks it for a value.
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c[source] * 2 }

  let state = cogs.derivedState(for: doubled)

  #expect(state.hasComputed == false)
  #expect(state.cachedValue == nil)
  #expect(state.dependencies.isEmpty)

  #expect(state.settledValue(in: cogs) == 2)

  #expect(state.hasComputed)
  #expect(state.cachedValue == 2)
}

@MainActor
@Test func `DerivedCogInfrastructure records a run that produced nil as a run`() {
  // The cache is storage presence, not value optionality: a state that computed
  // `nil` has computed, so the next read must not run the selector again.
  let cogs = Cogtext.forTesting()
  let nothing = Cog<Int?> { _ in nil }

  let state = cogs.derivedState(for: nothing)
  #expect(state.hasComputed == false)

  #expect(state.settledValue(in: cogs) == nil)

  #expect(state.hasComputed)
}

// MARK: - The tracking slot

@MainActor
@Test func `DerivedCogInfrastructure tracks the state whose selector is running`() {
  let cogs = Cogtext.forTesting()

  var consumerDuringRun: (any CogConsumer)?
  let observing = Cog<Int> { _ in
    consumerDuringRun = cogs.trackedConsumer
    return 1
  }

  #expect(cogs.trackedConsumer == nil)
  _ = cogs.peek(observing)

  #expect(consumerDuringRun === cogs.derivedState(for: observing))
  #expect(cogs.trackedConsumer == nil)
}

@MainActor
@Test func `DerivedCogInfrastructure hands tracking back after a nested run`() {
  // Runs nest whenever a selector reads a derived cog that has not computed.
  // The inner run must own the slot while it runs and give it back afterwards,
  // or the outer selector's later reads would attach to the wrong state.
  let cogs = Cogtext.forTesting()

  var slotDuringInnerRun: (any CogConsumer)?
  var slotAfterInnerRead: (any CogConsumer)?

  let inner = Cog<Int> { _ in
    slotDuringInnerRun = cogs.trackedConsumer
    return 1
  }
  let outer = Cog<Int> { c in
    let value = c[inner]
    slotAfterInnerRead = cogs.trackedConsumer
    return value + 1
  }

  #expect(cogs.peek(outer) == 2)

  #expect(slotDuringInnerRun === cogs.derivedState(for: inner))
  #expect(slotAfterInnerRead === cogs.derivedState(for: outer))
  #expect(cogs.trackedConsumer == nil)
}

// MARK: - Dependency capture

@MainActor
@Test func `DerivedCogInfrastructure records every cog a run read, in read order`() {
  let cogs = Cogtext.forTesting()

  let width = ManualCog<Int>(3)
  let height = ManualCog<Int>(4)
  let area = Cog<Int> { c in c[width] * c[height] }
  let label = Cog<String> { c in "\(c[area]) sq ft, \(c[width]) wide" }

  #expect(cogs.peek(label) == "12 sq ft, 3 wide")

  let areaState = cogs.derivedState(for: area)
  #expect(areaState.dependencies.count == 2)
  #expect(areaState.dependencies[0] === cogs.manualState(for: width))
  #expect(areaState.dependencies[1] === cogs.manualState(for: height))

  // A derived parent is recorded the same way a source is: an edge is an edge.
  let labelState = cogs.derivedState(for: label)
  #expect(labelState.dependencies.count == 2)
  #expect(labelState.dependencies[0] === areaState)
  #expect(labelState.dependencies[1] === cogs.manualState(for: width))
}

@MainActor
@Test func `DerivedCogInfrastructure records nothing for a selector that read nothing`() {
  let cogs = Cogtext.forTesting()
  let constant = Cog<Int> { _ in 7 }

  #expect(cogs.peek(constant) == 7)
  #expect(cogs.derivedState(for: constant).dependencies.isEmpty)
}

@MainActor
@Test func `DerivedCogInfrastructure keeps a peek out of the graph`() {
  // `cogs.peek` is an untracked one-shot read. Peeking at a derived cog that
  // way computes it and records what *it* read, and creates no edge to the
  // caller, because there is no caller in the graph to create one to.
  let cogs = Cogtext.forTesting()

  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c[source] * 2 }

  #expect(cogs.peek(doubled) == 2)

  #expect(cogs.derivedState(for: doubled).dependencies.count == 1)
  #expect(cogs.trackedConsumer == nil)
}
