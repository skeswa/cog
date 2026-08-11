#if DEBUG

import Cog
import CogTesting
import Testing

// Debug history is its own rung on the observation ladder, so these tests read
// `cogs.debugHistory` and nothing else — no `@testable import Cog`, because the
// ring is storage and a later core swap must leave these tests untouched.
// What a label *prints* is `M1-31b`'s claim (DECL-10, DECL-11) and is never
// asserted here; these tests only ask what happened, and under which turn.

extension Cogtext {
  fileprivate func bumpTheCounter(_ count: ManualCog<Int>) {
    commit { w in w[count] += 1 }
  }
}

@MainActor
@Test func `HIST-01 every turn lands in history under the name it was given`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)

  #expect(cogs.debugHistory.count == 0)

  cogs.commit("first") { w in w[count] = 1 }
  cogs.commit("second") { w in w[count] = 2 }

  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.count == 2)
  #expect(turns.map(\.name) == ["first", "second"])
  #expect(turns.map(\.turn) == [1, 2])
}

@MainActor
@Test func `HIST-01 an unnamed turn lands under the op that committed it`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)

  cogs.bumpTheCounter(count)

  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.count == 1)
  // `hasPrefix`, not `==`: whether `#function` spells a method with one
  // unlabeled argument `bumpTheCounter` or `bumpTheCounter(_:)` is the
  // compiler's business, and HIST-01 asks only that the op names the turn.
  #expect(turns.first?.name.hasPrefix("bumpTheCounter") == true)
}

@MainActor
@Test func `HIST-02 history records writes and recomputations`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in c.get(source) * 2 }

  #expect(cogs.read(doubled) == 2)

  let afterFirstRead = cogs.debugHistory.entries
  #expect(afterFirstRead.filter { $0.event == .recompute }.count == 1)
  #expect(afterFirstRead.filter { $0.event == .write }.isEmpty)

  cogs.commit("raise") { w in w[source] = 5 }
  #expect(cogs.read(doubled) == 10)

  let afterWrite = cogs.debugHistory.entries
  #expect(afterWrite.filter { $0.event == .write }.count == 1)
  #expect(afterWrite.filter { $0.event == .recompute }.count == 2)
  // The write belongs to the turn that made it, not to the read before it.
  #expect(afterWrite.first { $0.event == .write }?.turn == 1)

  cogs.commit("raise again") { w in w[source] = 5 }
  #expect(cogs.read(doubled) == 10)

  // A write that changed nothing is not a write, and causes no recomputation.
  // The turn it asked for still happened and still says so.
  let afterEqualWrite = cogs.debugHistory.entries
  #expect(afterEqualWrite.filter { $0.event == .turn }.count == 2)
  #expect(afterEqualWrite.filter { $0.event == .write }.count == 1)
  #expect(afterEqualWrite.filter { $0.event == .recompute }.count == 2)
}

@MainActor
@Test func `HIST-02 a diamond records one recomputation for each node that ran`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let left = Cog<Int> { c in c.get(source) + 1 }
  let right = Cog<Int> { c in c.get(source) + 2 }
  let sum = Cog<Int> { c in c.get(left) + c.get(right) }

  #expect(cogs.read(sum) == 5)
  #expect(cogs.debugHistory.entries.filter { $0.event == .recompute }.count == 3)

  cogs.commit("bump") { w in w[source] = 2 }
  #expect(cogs.read(sum) == 7)

  let entries = cogs.debugHistory.entries
  #expect(entries.filter { $0.event == .write }.count == 1)
  // Three more runs, not four: the shared consumer settles once even though
  // both of its parents changed.
  #expect(entries.filter { $0.event == .recompute }.count == 6)
}

@MainActor
@Test func `HIST-03 history is bounded and drops its oldest entries`() {
  let cogs = Cogtext.forTesting()
  let capacity = cogs.debugHistory.capacity
  let extra = 8
  var highWaterMark = 0

  // Each of these turns writes nothing, so it records exactly one entry and
  // the arithmetic below is exact.
  for index in 0..<(capacity + extra) {
    cogs.commit("turn \(index)") { _ in }
    highWaterMark = max(highWaterMark, cogs.debugHistory.count)
  }

  let history = cogs.debugHistory
  // Two-sided on purpose: above the cap means the bound leaked, below it means
  // the ring never filled and the eviction assertions below prove nothing.
  #expect(highWaterMark == capacity)
  #expect(history.count == capacity)
  #expect(history.entries.count == capacity)
  #expect(history.entries.first?.name == "turn \(extra)")
  #expect(history.entries.last?.name == "turn \(capacity + extra - 1)")
}

#endif
