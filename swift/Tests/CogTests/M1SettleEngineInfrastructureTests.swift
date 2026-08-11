import CogTesting
import Testing

@testable import Cog

// `M1-06aa`'s settle-engine foundation, asserted directly. These tests green
// no scenario: `M1-06ab`'s behavior test proves that a public read actually
// settles a chain. Keeping flags, versions, and stack storage here lets the
// data-oriented core replace all three without changing that test.

@MainActor
@Test func `SettleEngineInfrastructure gives fresh nodes the right state and versions`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c.get(source) * 2 }

  let sourceNode = cogs.manualNode(for: source)
  let derivedNode = cogs.derivedNode(for: doubled)

  // A source is current from birth. A derived node has no value yet, so its
  // first read must take the compute path rather than mistake it for clean.
  #expect(sourceNode.settleState == .clean)
  #expect(derivedNode.settleState == .dirty)

  #expect(cogs.revision == .initial)
  #expect(sourceNode.changedAt == .initial)
  #expect(sourceNode.checkedAt == .initial)
  #expect(derivedNode.changedAt == .initial)
  #expect(derivedNode.checkedAt == .initial)
}

@MainActor
@Test func `SettleEngineInfrastructure advances revisions monotonically`() {
  let cogs = Cogtext.forTesting()

  let first = cogs.advanceRevision()
  let second = cogs.advanceRevision()

  #expect(first > .initial)
  #expect(second > first)
  #expect(cogs.revision == second)
}

@MainActor
@Test func `SettleEngineInfrastructure never weakens an invalidation`() {
  let cogs = Cogtext.forTesting()
  let source = cogs.manualNode(for: ManualCog<Int>(1))

  source.markForCheck()
  #expect(source.settleState == .check)

  source.markDirty()
  #expect(source.settleState == .dirty)

  // A farther-away propagation path may ask a node to CHECK after a direct
  // parent already made it DIRTY. That must not lose the stronger state.
  source.markForCheck()
  #expect(source.settleState == .dirty)
}

@MainActor
@Test func `SettleEngineInfrastructure distinguishes change from verification`() {
  let cogs = Cogtext.forTesting()
  let source = cogs.manualNode(for: ManualCog<Int>(1))

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
  let cogs = Cogtext.forTesting()
  let source = cogs.manualNode(for: ManualCog<Int>(1))
  let derived = cogs.derivedNode(for: Cog<Int> { _ in 2 })

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
  let cogs = Cogtext.forTesting()
  let first = cogs.derivedNode(for: Cog<Int> { _ in 1 })
  let second = cogs.derivedNode(for: Cog<Int> { _ in 2 })

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
