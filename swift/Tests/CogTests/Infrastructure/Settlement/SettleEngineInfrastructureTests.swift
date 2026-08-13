import CogTesting
import Testing

@testable import Cog

// Internal checks for settle flags, versions, and stack storage. Scenario tests
// cover settlement through public reads.

@MainActor
@Test func `SettleEngineInfrastructure gives fresh states the right state and versions`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c[source] * 2 }

  let sourceState = cogs.manualState(for: source)
  let derivedState = cogs.derivedState(for: doubled)

  // A source is current from birth. A derived state has no value yet, so its
  // first read must take the compute path rather than mistake it for clean.
  #expect(sourceState.settleState == .clean)
  #expect(derivedState.settleState == .dirty)

  #expect(cogs.revision == .initial)
  #expect(sourceState.changedAt == .initial)
  #expect(sourceState.checkedAt == .initial)
  #expect(derivedState.changedAt == .initial)
  #expect(derivedState.checkedAt == .initial)
}

@MainActor
@Test func `SettleEngineInfrastructure advances revisions monotonically`() {
  let cogs = Cogs.forTesting()

  let first = cogs.advanceRevision()
  let second = cogs.advanceRevision()

  #expect(first > .initial)
  #expect(second > first)
  #expect(cogs.revision == second)
}

@MainActor
@Test func `SettleEngineInfrastructure never weakens an invalidation`() {
  let cogs = Cogs.forTesting()
  let source = cogs.manualState(for: ManualCog<Int>(1))

  source.markForCheck()
  #expect(source.settleState == .check)

  source.markDirty()
  #expect(source.settleState == .dirty)

  // A farther-away propagation path may ask a state to CHECK after a direct
  // parent already made it DIRTY. That must not lose the stronger state.
  source.markForCheck()
  #expect(source.settleState == .dirty)
}

@MainActor
@Test func `SettleEngineInfrastructure distinguishes change from verification`() {
  let cogs = Cogs.forTesting()
  let source = cogs.manualState(for: ManualCog<Int>(1))

  let changed = cogs.advanceRevision()
  source.markChanged(at: changed)

  #expect(source.settleState == .clean)
  #expect(source.changedAt == changed)
  #expect(source.checkedAt == changed)

  source.markForCheck()
  let merelyChecked = cogs.advanceRevision()
  source.markChecked(at: merelyChecked)

  #expect(source.settleState == .clean)
  #expect(source.changedAt == changed)
  #expect(source.checkedAt == merelyChecked)
}

@MainActor
@Test func `SettleEngineInfrastructure stores enter and exit frames in LIFO order`() {
  let cogs = Cogs.forTesting()
  let source = cogs.manualState(for: ManualCog<Int>(1))
  let derived = cogs.derivedState(for: Cog<Int> { _ in 2 })

  cogs.settleStack.reset(startingAt: derived)
  cogs.settleStack.pushExit(derived)
  cogs.settleStack.pushEnter(source)

  guard case .enter(let entered)? = cogs.settleStack.popLast() else {
    Issue.record("The dependency enter frame was not on top of the settle stack")
    return
  }
  #expect(entered === source)

  guard case .exit(let exited)? = cogs.settleStack.popLast() else {
    Issue.record("The derived exit frame did not follow its dependency")
    return
  }
  #expect(exited === derived)

  guard case .enter(let root)? = cogs.settleStack.popLast() else {
    Issue.record("The root enter frame was not retained")
    return
  }
  #expect(root === derived)
  #expect(cogs.settleStack.isEmpty)
}

@MainActor
@Test func `SettleEngineInfrastructure reuses one stack and clears abandoned frames`() {
  let cogs = Cogs.forTesting()
  let first = cogs.derivedState(for: Cog<Int> { _ in 1 })
  let second = cogs.derivedState(for: Cog<Int> { _ in 2 })

  cogs.settleStack.reset(startingAt: first)
  cogs.settleStack.pushExit(first)
  cogs.settleStack.pushEnter(second)
  let reservedCapacity = cogs.settleStack.capacity

  // A fresh traversal starts from exactly one root even if an earlier walk
  // stopped early, and retains its allocation for the next graph read.
  cogs.settleStack.reset(startingAt: second)
  #expect(cogs.settleStack.count == 1)
  #expect(cogs.settleStack.capacity >= reservedCapacity)

  guard case .enter(let root)? = cogs.settleStack.popLast() else {
    Issue.record("Reset did not leave exactly the new root enter frame")
    return
  }
  #expect(root === second)
  #expect(cogs.settleStack.isEmpty)
}

@MainActor
@Test func `SettleEngineInfrastructure severs strong graph chains before context teardown`() {
  var cogs: Cogs? = Cogs.forTesting()
  weak let releasedContext = cogs

  let source = ManualCog<Int>(1)
  let middle = Cog<Int> { c in c[source] + 1 }
  let root = Cog<Int> { c in c[middle] + 1 }
  #expect(cogs?.peek(root) == 3)

  let token = cogs?.run { c in _ = c[root] }
  let retainedStates = cogs.map { Array($0.states.values) } ?? []
  let retainedReaction = token?.reaction

  #expect(retainedStates.compactMap { $0 as? any DerivedCogSettleState }.count == 2)
  #expect(retainedReaction?.dependencies.count == 1)

  cogs = nil

  #expect(releasedContext == nil)
  #expect(
    retainedStates.compactMap { $0 as? any DerivedCogSettleState }
      .allSatisfy { $0.dependencies.isEmpty }
  )
  #expect(retainedReaction?.dependencies.isEmpty == true)
  _ = token
}
