import Cog
import CogTesting
import Testing

// Turn composition proved from the outside, through ops, reactions, and debug
// history. Nothing here reaches for `CogTurnID` or `turnPhase` — that is
// `TurnCompositionInfrastructureTests`, which greens no scenario and is free
// to change with a later core.
//
// The history halves are gated, because the whole history surface is. The
// flush-count and reaction-count halves need no debug surface and stay
// ungated, so the release leg keeps proving that nested commits join and
// sibling commits do not.

extension Cogtext {
  /// An op whose body nests a second op, which nests a third.
  fileprivate func transfer(_ amount: Int, from: ManualCog<Int>, to: ManualCog<Int>) {
    commit { w in
      w[from] -= amount
      self.credit(amount, to: to)
    }
  }

  fileprivate func credit(_ amount: Int, to: ManualCog<Int>) {
    commit("credit") { _ in
      self.recordCredit(amount, to: to)
    }
  }

  fileprivate func recordCredit(_ amount: Int, to: ManualCog<Int>) {
    commit("credit.record") { w in w[to] += amount }
  }

  /// An op that lets `#function` name its own turn.
  fileprivate func applyDiscount(_ price: ManualCog<Int>) {
    commit { w in w[price] -= 1 }
  }

  fileprivate func recordFollowup(_ followup: ManualCog<Int>) {
    commit("followup.record") { w in w[followup] = 1 }
  }

  fileprivate func stepOne(_ counter: ManualCog<Int>) {
    commit { w in w[counter] = 1 }
  }

  fileprivate func stepTwo(_ counter: ManualCog<Int>) {
    commit { w in w[counter] = 2 }
  }
}

@MainActor
@Test func `TURN-05 a commit inside a commit flushes once when the outer body ends`() {
  let cogs = Cogtext.forTesting()
  let left = ManualCog<Int>(0)
  let right = ManualCog<Int>(0)
  var selectorRuns = 0
  let total = Cog<Int> { c in
    selectorRuns += 1
    return c.get(left) + c.get(right)
  }
  var events: [String] = []

  // Registered before the turn under test on purpose: a registration made
  // inside an accumulating body would run immediately and again at that turn's
  // flush, putting a run in `events` that means nothing here.
  let token = cogs.run { c in events.append("react:\(c.get(total))") }
  #expect(events == ["react:0"])
  events.removeAll()
  selectorRuns = 0

  var innerWriterSaw: [Int] = []
  var midBody: [String] = []

  cogs.commit("outer") { w in
    w[left] = 1
    cogs.commit("inner") { inner in
      // The inner writer is the outer turn's writer, so it reads back what the
      // outer body staged a line ago.
      innerWriterSaw.append(inner[left])
      inner[right] = 2
    }
    // The inner commit has returned and nothing has crossed the boundary yet:
    // normal reads still see committed values, and no reaction has run.
    midBody.append("reads:\(cogs.read(left))/\(cogs.read(right))")
    midBody.append("reactions:\(events.count)")
  }

  // No await and no polling: the statement after the outer commit already sees
  // the whole flush, and that flush happened exactly once.
  #expect(cogs.read(left) == 1)
  #expect(cogs.read(right) == 2)
  #expect(cogs.read(total) == 3)

  #expect(innerWriterSaw == [1])
  #expect(midBody == ["reads:0/0", "reactions:0"])
  // One run, and it saw both writes together — never 1 and then 3.
  #expect(events == ["react:3"])
  #expect(selectorRuns == 1)
  _ = token
}

@MainActor
@Test func `TURN-13 sibling commits each flush and react before the next begins`() {
  let cogs = Cogtext.forTesting()
  let counter = ManualCog<Int>(0)
  var events: [String] = []

  let token = cogs.run { c in events.append("react:\(c.get(counter))") }
  events.removeAll()

  // One event handler, two commits back to back, nothing suspended between.
  func handleTap() {
    cogs.commit("step.one") { w in
      events.append("body:1")
      w[counter] = 1
    }
    cogs.commit("step.two") { w in
      events.append("body:2")
      w[counter] = 2
    }
  }

  handleTap()

  // The interleave is the claim: the first turn is completely over — flushed
  // and reacted, at its own value — before the second body starts.
  #expect(events == ["body:1", "react:1", "body:2", "react:2"])
  _ = token
}

#if DEBUG

@MainActor
@Test func `TURN-05 nested commits are one turn in history`() {
  let cogs = Cogtext.forTesting()
  let checking = ManualCog<Int>(5)
  let savings = ManualCog<Int>(0)

  cogs.transfer(2, from: checking, to: savings)

  #expect(cogs.read(checking) == 3)
  #expect(cogs.read(savings) == 2)

  let entries = cogs.debugHistory.entries
  let turns = entries.filter { $0.event == .turn }
  #expect(turns.count == 1)
  // `hasPrefix`, not `==`: how `#function` spells this method's argument
  // labels is the compiler's business, not this scenario's.
  #expect(turns.first?.name.hasPrefix("transfer") == true)
  // The joined commits' own names are gone, which is what joining means.
  #expect(turns.contains { $0.name == "credit" } == false)
  #expect(turns.contains { $0.name == "credit.record" } == false)
  // Two sources changed, so two writes crossed the boundary — once each, and
  // every entry belongs to the one turn.
  #expect(entries.filter { $0.event == .write }.count == 2)
  #expect(entries.allSatisfy { $0.turn == 1 })
}

@MainActor
@Test func `TURN-06 a turn is named by its op or by the name I pass`() {
  let cogs = Cogtext.forTesting()
  let price = ManualCog<Int>(10)

  cogs.applyDiscount(price)
  cogs.commit("checkout.submit") { w in w[price] = 0 }

  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.count == 2)
  #expect(turns.first?.name.hasPrefix("applyDiscount") == true)
  #expect(turns.last?.name == "checkout.submit")
}

@MainActor
@Test func `TURN-06 a joined commit contributes no name and a queued one keeps its own`() {
  let cogs = Cogtext.forTesting()
  let trigger = ManualCog<Int>(0)
  let note = ManualCog<Int>(0)
  let followup = ManualCog<Int>(0)

  let token = cogs.run { c in
    guard c.get(trigger) == 1 else { return }
    cogs.recordFollowup(followup)
  }

  cogs.commit("outer") { w in
    w[trigger] = 1
    cogs.commit("ignored") { inner in inner[note] = 5 }
  }

  // Three names were offered and two turns happened. The joined body's name is
  // discarded, while the body the flush queued keeps the name its own call site
  // gave it rather than inheriting the turn that queued it.
  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.map(\.name) == ["outer", "followup.record"])
  _ = token
}

@MainActor
@Test func `TURN-13 sibling commits are two named turns in history`() {
  let cogs = Cogtext.forTesting()
  let counter = ManualCog<Int>(0)

  cogs.stepOne(counter)
  cogs.stepTwo(counter)

  let entries = cogs.debugHistory.entries
  let turns = entries.filter { $0.event == .turn }
  #expect(turns.count == 2)
  #expect(turns.map(\.turn) == [1, 2])
  #expect(turns.first?.name.hasPrefix("stepOne") == true)
  #expect(turns.last?.name.hasPrefix("stepTwo") == true)
  // Each turn's write is stamped with that turn, so the two never merge.
  #expect(entries.filter { $0.event == .write }.map(\.turn) == [1, 2])
}

#endif
