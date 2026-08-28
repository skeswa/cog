import Cog
import CogTesting
import Testing

// Reactions and debug history expose turn composition without inspecting turn
// internals. Only history assertions require a debug build.

extension Cogs {
  /// An op whose body nests a second op, which nests a third.
  fileprivate func transfer(_ amount: Int, from: Cog<Int>.Manual, to: Cog<Int>.Manual) {
    turn { c in
      c[from] -= amount
      self.credit(amount, to: to)
    }
  }

  fileprivate func credit(_ amount: Int, to: Cog<Int>.Manual) {
    turn("credit") { _ in
      self.recordCredit(amount, to: to)
    }
  }

  fileprivate func recordCredit(_ amount: Int, to: Cog<Int>.Manual) {
    turn("credit.record") { c in c[to] += amount }
  }

  /// An op that lets `#function` name its own turn.
  fileprivate func applyDiscount(_ price: Cog<Int>.Manual) {
    turn { c in c[price] -= 1 }
  }

  fileprivate func recordFollowup(_ followup: Cog<Int>.Manual) {
    turn("followup.record") { c in c[followup] = 1 }
  }

  fileprivate func stepOne(_ counter: Cog<Int>.Manual) {
    turn { c in c[counter] = 1 }
  }

  fileprivate func stepTwo(_ counter: Cog<Int>.Manual) {
    turn { c in c[counter] = 2 }
  }
}

@MainActor
@Test func `TURN-05 a turn inside a turn flushes once when the outer body ends`() {
  let (cogs, m) = Cogs.forTestingWithController()
  let left = Cog<Int>.Manual { 0 }
  let right = Cog<Int>.Manual { 0 }
  var selectorRuns = 0
  let total = Cog<Int> { c in
    selectorRuns += 1
    return c[left] + c[right]
  }
  var events: [String] = []

  // Register before the tested turn. Registering inside its body would add an
  // immediate run and another at flush, creating unrelated `events` entries.
  m.run { c in events.append("react:\(c[total])") }
  #expect(events == ["react:0"])
  events.removeAll()
  selectorRuns = 0

  var innerWriterSaw: [Int] = []
  var midBody: [String] = []

  cogs.turn("outer") { c in
    c[left] = 1
    cogs.turn("inner") { c in
      // The inner writer is the outer turn's writer, so it reads back what the
      // outer body staged a line ago.
      innerWriterSaw.append(c[left])
      c[right] = 2
    }
    // The inner turn has returned and nothing has crossed the boundary yet:
    // normal reads still see published values, and no reaction has run.
    midBody.append("reads:\(cogs.peek(left))/\(cogs.peek(right))")
    midBody.append("reactions:\(events.count)")
  }

  // No await and no polling: the statement after the outer turn already sees
  // the whole flush, and that flush happened exactly once.
  #expect(cogs.peek(left) == 1)
  #expect(cogs.peek(right) == 2)
  #expect(cogs.peek(total) == 3)

  #expect(innerWriterSaw == [1])
  #expect(midBody == ["reads:0/0", "reactions:0"])
  // One run saw both writes together, never 1 and then 3.
  #expect(events == ["react:3"])
  #expect(selectorRuns == 1)
}

@MainActor
@Test func `TURN-13 sibling turns each flush and react before the next begins`() {
  let (cogs, m) = Cogs.forTestingWithController()
  let counter = Cog<Int>.Manual { 0 }
  var events: [String] = []

  m.run { c in events.append("react:\(c[counter])") }
  events.removeAll()

  // One event handler, two turns back to back, nothing suspended between.
  func handleTap() {
    cogs.turn("step.one") { c in
      events.append("body:1")
      c[counter] = 1
    }
    cogs.turn("step.two") { c in
      events.append("body:2")
      c[counter] = 2
    }
  }

  handleTap()

  // The first turn flushes and reacts at its own value before the second body
  // starts.
  #expect(events == ["body:1", "react:1", "body:2", "react:2"])
}

#if DEBUG

@MainActor
@Test func `TURN-05 nested turns are one turn in history`() {
  let (cogs, m) = Cogs.forTestingWithController()
  let checking = Cog<Int>.Manual { 5 }
  let savings = Cog<Int>.Manual { 0 }

  cogs.transfer(2, from: checking, to: savings)

  #expect(cogs.peek(checking) == 3)
  #expect(cogs.peek(savings) == 2)

  let entries = cogs.debugHistory.entries
  let turns = entries.filter { $0.event == .turn }
  #expect(turns.count == 1)
  // `hasPrefix`, not `==`: how `#function` spells this method's argument
  // labels is the compiler's business, not this scenario's.
  #expect(turns.first?.name.hasPrefix("transfer") == true)
  // The joined turns' own names are gone, which is what joining means.
  #expect(turns.contains { $0.name == "credit" } == false)
  #expect(turns.contains { $0.name == "credit.record" } == false)
  // Two sources changed, so two writes crossed the boundary once each. Every
  // entry belongs to the same turn.
  #expect(entries.filter { $0.event == .write }.count == 2)
  #expect(entries.allSatisfy { $0.turn == 1 })
}

@MainActor
@Test func `TURN-06 a turn is named by its op or by the name I pass`() {
  let (cogs, m) = Cogs.forTestingWithController()
  let price = Cog<Int>.Manual { 10 }

  cogs.applyDiscount(price)
  cogs.turn("checkout.submit") { c in c[price] = 0 }

  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.count == 2)
  #expect(turns.first?.name.hasPrefix("applyDiscount") == true)
  #expect(turns.last?.name == "checkout.submit")
}

@MainActor
@Test func `TURN-06 a joined turn contributes no name and a queued one keeps its own`() {
  let (cogs, m) = Cogs.forTestingWithController()
  let trigger = Cog<Int>.Manual { 0 }
  let note = Cog<Int>.Manual { 0 }
  let followup = Cog<Int>.Manual { 0 }

  m.run { c in
    guard c[trigger] == 1 else { return }
    cogs.recordFollowup(followup)
  }

  cogs.turn("outer") { c in
    c[trigger] = 1
    cogs.turn("ignored") { c in c[note] = 5 }
  }

  // Three names were offered and two turns happened. The joined body's name is
  // discarded, while the body the flush queued keeps the name its own call site
  // gave it rather than inheriting the turn that queued it.
  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.map(\.name) == ["outer", "followup.record"])
}

@MainActor
@Test func `TURN-13 sibling turns are two named turns in history`() {
  let (cogs, m) = Cogs.forTestingWithController()
  let counter = Cog<Int>.Manual { 0 }

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
