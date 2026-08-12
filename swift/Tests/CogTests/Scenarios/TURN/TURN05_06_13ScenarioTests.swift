import Cog
import CogTesting
import Testing

// Reactions and debug history expose turn composition without inspecting turn
// internals. Only history assertions require a debug build.

extension Cogtext {
  /// An op whose body nests a second op, which nests a third.
  fileprivate func transfer(_ amount: Int, from: ManualCog<Int>, to: ManualCog<Int>) {
    commit { c in
      c[from] -= amount
      self.credit(amount, to: to)
    }
  }

  fileprivate func credit(_ amount: Int, to: ManualCog<Int>) {
    commit("credit") { _ in
      self.recordCredit(amount, to: to)
    }
  }

  fileprivate func recordCredit(_ amount: Int, to: ManualCog<Int>) {
    commit("credit.record") { c in c[to] += amount }
  }

  /// An op that lets `#function` name its own turn.
  fileprivate func applyDiscount(_ price: ManualCog<Int>) {
    commit { c in c[price] -= 1 }
  }

  fileprivate func recordFollowup(_ followup: ManualCog<Int>) {
    commit("followup.record") { c in c[followup] = 1 }
  }

  fileprivate func stepOne(_ counter: ManualCog<Int>) {
    commit { c in c[counter] = 1 }
  }

  fileprivate func stepTwo(_ counter: ManualCog<Int>) {
    commit { c in c[counter] = 2 }
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
    return c[left] + c[right]
  }
  var events: [String] = []

  // Registered before the turn under test on purpose: a registration made
  // inside an accumulating body would run immediately and again at that turn's
  // flush, putting a run in `events` that means nothing here.
  let token = cogs.run { c in events.append("react:\(c[total])") }
  #expect(events == ["react:0"])
  events.removeAll()
  selectorRuns = 0

  var innerWriterSaw: [Int] = []
  var midBody: [String] = []

  cogs.commit("outer") { c in
    c[left] = 1
    cogs.commit("inner") { c in
      // The inner writer is the outer turn's writer, so it reads back what the
      // outer body staged a line ago.
      innerWriterSaw.append(c[left])
      c[right] = 2
    }
    // The inner commit has returned and nothing has crossed the boundary yet:
    // normal reads still see committed values, and no reaction has run.
    midBody.append("reads:\(cogs.peek(left))/\(cogs.peek(right))")
    midBody.append("reactions:\(events.count)")
  }

  // No await and no polling: the statement after the outer commit already sees
  // the whole flush, and that flush happened exactly once.
  #expect(cogs.peek(left) == 1)
  #expect(cogs.peek(right) == 2)
  #expect(cogs.peek(total) == 3)

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

  let token = cogs.run { c in events.append("react:\(c[counter])") }
  events.removeAll()

  // One event handler, two commits back to back, nothing suspended between.
  func handleTap() {
    cogs.commit("step.one") { c in
      events.append("body:1")
      c[counter] = 1
    }
    cogs.commit("step.two") { c in
      events.append("body:2")
      c[counter] = 2
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

  #expect(cogs.peek(checking) == 3)
  #expect(cogs.peek(savings) == 2)

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
  cogs.commit("checkout.submit") { c in c[price] = 0 }

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
    guard c[trigger] == 1 else { return }
    cogs.recordFollowup(followup)
  }

  cogs.commit("outer") { c in
    c[trigger] = 1
    cogs.commit("ignored") { c in c[note] = 5 }
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
