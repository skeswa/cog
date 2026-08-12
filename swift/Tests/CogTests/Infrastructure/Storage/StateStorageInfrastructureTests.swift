import CogTesting
import Testing

@testable import Cog

// `M1-01b`'s storage layer, asserted directly. These tests green no scenario:
// the behavior a user was promised is in `DECL01ScenarioTests.swift`, which
// stays on the public surface. What is checked here is the invariant that
// behavior rests on — one state per descriptor and key, created on first use —
// and there is no public way to observe it yet, because boxes (`M1-02`) and
// keyed writes (`M1-04b`) are what make per-key and per-context identity visible
// from outside. Until they land, this file is the only thing standing between
// a silent storage bug and the tasks that build on it.
//
// Being implementation tests, they are allowed to reach through `@testable`,
// and they are expected to change when the data-oriented core (`M6`) replaces
// dictionary storage. The scenario tests are not.

// MARK: - Laziness

@MainActor
@Test func `StateStorageInfrastructure creates nothing until a declaration is used`() {
  let cogs = Cogtext.forTesting()
  #expect(cogs.states.isEmpty)

  // Declaring allocates a descriptor and touches no context.
  let retryLimit = ManualCog<Int>(3)
  let unused = ManualCog<Int>(0)
  #expect(cogs.states.isEmpty)

  _ = cogs.read(retryLimit)

  // The one read made one state, and the declaration nobody read has none.
  #expect(cogs.states.count == 1)
  #expect(cogs.states[CogStateIdentity(descriptor: unused.descriptor.identity, key: nil)] == nil)
}

// MARK: - One state per descriptor and key

@MainActor
@Test func `StateStorageInfrastructure reuses one state for one declaration`() {
  let cogs = Cogtext.forTesting()
  let retryLimit = ManualCog<Int>(3)

  let first = cogs.manualState(for: retryLimit)
  let second = cogs.manualState(for: retryLimit)

  #expect(first === second)
  #expect(cogs.states.count == 1)
}

@MainActor
@Test func `StateStorageInfrastructure resolves a copied value reference to the same state`() {
  // Value references are values that get copied and passed around freely; copying one must
  // not be a way to end up with a second piece of state.
  let cogs = Cogtext.forTesting()
  let declared = ManualCog<Int>(3)
  let copied = declared

  #expect(cogs.manualState(for: declared) === cogs.manualState(for: copied))
  #expect(cogs.states.count == 1)
}

@MainActor
@Test func `StateStorageInfrastructure gives every key of a declaration its own state`() {
  // The seam `box[key]` uses in `M1-02`: one descriptor, one state per key.
  let cogs = Cogtext.forTesting()
  let weather = ManualCog<Int>(0)

  let here = ManualCog(descriptor: weather.descriptor, key: 90210)
  let there = ManualCog(descriptor: weather.descriptor, key: 10001)
  let hereAgain = ManualCog(descriptor: weather.descriptor, key: 90210)

  #expect(cogs.manualState(for: here) !== cogs.manualState(for: there))
  #expect(cogs.manualState(for: here) === cogs.manualState(for: hereAgain))
  #expect(cogs.states.count == 2)
}

@MainActor
@Test func `StateStorageInfrastructure keeps a keyless declaration separate from its keys`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  let keyed = ManualCog(descriptor: source.descriptor, key: 0)

  #expect(cogs.manualState(for: source) !== cogs.manualState(for: keyed))
  #expect(cogs.states.count == 2)
}

@MainActor
@Test func `StateStorageInfrastructure tells identical declarations apart`() {
  // Same type, same starting value, same label — two declarations, so two
  // states. Identity is the descriptor object and nothing else (§2.3).
  let cogs = Cogtext.forTesting()
  let left = ManualCog<Int>(0, name: "twin")
  let right = ManualCog<Int>(0, name: "twin")

  #expect(cogs.manualState(for: left) !== cogs.manualState(for: right))
  #expect(cogs.states.count == 2)
}

// MARK: - Per context

@MainActor
@Test func `StateStorageInfrastructure gives every context its own states`() {
  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()
  let retryLimit = ManualCog<Int>(3)

  let inFirst = first.manualState(for: retryLimit)
  let inSecond = second.manualState(for: retryLimit)

  #expect(inFirst !== inSecond)
  #expect(first.states.count == 1)
  #expect(second.states.count == 1)
}

// MARK: - What a state starts at

@MainActor
@Test func `StateStorageInfrastructure starts a state at its declaration's starting value`() {
  let cogs = Cogtext.forTesting()
  let retryLimit = ManualCog<Int>(3)
  let keyed = ManualCog(descriptor: retryLimit.descriptor, key: 90210)

  #expect(cogs.manualState(for: retryLimit).currentValue == 3)
  #expect(cogs.manualState(for: keyed).currentValue == 3)
}

@MainActor
@Test func `StateStorageInfrastructure keeps a state's label and key for diagnostics`() {
  let cogs = Cogtext.forTesting()
  let weather = ManualCog<Int>(0, name: "weather")
  let keyed = ManualCog(descriptor: weather.descriptor, key: 90210)

  let state = cogs.manualState(for: keyed)

  #expect("\(state.label)" == "weather")
  #expect(state.key == AnyHashable(90210))
  #expect(cogs.manualState(for: weather).key == nil)
}
