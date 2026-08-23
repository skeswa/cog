#if DEBUG

import Cog
import CogTesting
import Testing

// These tests use the public debug history. Label rendering has separate
// coverage.

extension Cogs {
  fileprivate func bumpTheCounter(_ count: Cog<Int>.Manual) {
    turn { c in c[count] += 1 }
  }
}

@MainActor
@Test func `HIST-01 every turn lands in history under the name it was given`() {
  let cogs = Cogs.forTesting()
  let count = Cog<Int>.Manual(0)

  #expect(cogs.debugHistory.count == 0)

  cogs.turn("first") { c in c[count] = 1 }
  cogs.turn("second") { c in c[count] = 2 }

  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.count == 2)
  #expect(turns.map(\.name) == ["first", "second"])
  #expect(turns.map(\.turn) == [1, 2])
}

@MainActor
@Test func `HIST-01 an unnamed turn lands under the op that published it`() {
  let cogs = Cogs.forTesting()
  let count = Cog<Int>.Manual(0)

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
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(1)
  let doubled = Cog<Int> { c in c[source] * 2 }

  #expect(cogs.peek(doubled) == 2)

  let afterFirstRead = cogs.debugHistory.entries
  #expect(afterFirstRead.filter { $0.event == .recompute }.count == 1)
  #expect(afterFirstRead.filter { $0.event == .write }.isEmpty)

  cogs.turn("raise") { c in c[source] = 5 }
  #expect(cogs.peek(doubled) == 10)

  let afterWrite = cogs.debugHistory.entries
  #expect(afterWrite.filter { $0.event == .write }.count == 1)
  #expect(afterWrite.filter { $0.event == .recompute }.count == 2)
  // The write belongs to the turn that made it, not to the read before it.
  #expect(afterWrite.first { $0.event == .write }?.turn == 1)

  cogs.turn("raise again") { c in c[source] = 5 }
  #expect(cogs.peek(doubled) == 10)

  // A write that changed nothing is not a write, and causes no recomputation.
  // The turn it asked for still happened and still says so.
  let afterEqualWrite = cogs.debugHistory.entries
  #expect(afterEqualWrite.filter { $0.event == .turn }.count == 2)
  #expect(afterEqualWrite.filter { $0.event == .write }.count == 1)
  #expect(afterEqualWrite.filter { $0.event == .recompute }.count == 2)
}

@MainActor
@Test func `HIST-02 keyed writes and recomputations record their keys`() {
  // A keyed entry names the exact state, `label[key]`, so history can tell
  // which item of a box wrote or ran — the same rendering turns and task
  // names use.
  let cogs = Cogs.forTesting()
  let temperatures = CogBox<Int, String>.Manual(60, name: "temperature")
  let weather = CogBox<String, String>(
    { c, key in "temp: \(c[temperatures[key]])" },
    name: "weather"
  )

  #expect(cogs.peek(weather["home"]) == "temp: 60")

  cogs.turn("warm up") { c in c[temperatures["home"]] = 80 }
  #expect(cogs.peek(weather["home"]) == "temp: 80")

  let entries = cogs.debugHistory.entries
  #expect(entries.filter { $0.event == .write }.map(\.name) == ["temperature[home]"])
  #expect(
    entries.filter { $0.event == .recompute }.map(\.name) == ["weather[home]", "weather[home]"]
  )
}

@MainActor
@Test func `HIST-02 a diamond records one recomputation for each state that ran`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(1)
  let left = Cog<Int> { c in c[source] + 1 }
  let right = Cog<Int> { c in c[source] + 2 }
  let sum = Cog<Int> { c in c[left] + c[right] }

  #expect(cogs.peek(sum) == 5)
  #expect(cogs.debugHistory.entries.filter { $0.event == .recompute }.count == 3)

  cogs.turn("bump") { c in c[source] = 2 }
  #expect(cogs.peek(sum) == 7)

  let entries = cogs.debugHistory.entries
  #expect(entries.filter { $0.event == .write }.count == 1)
  // Three more runs, not four: the shared consumer settles once even though
  // both of its parents changed.
  #expect(entries.filter { $0.event == .recompute }.count == 6)
}

@MainActor
@Test func `HIST-05 a named watch's run lands in history under its effect name`() {
  let temperature = Cog<Int>.Manual(60)
  var alerts = 0

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe(name: "Weather") { m in
      m.watch(temperature, initial: .skip, name: "niceAlert") { _, _ in
        alerts += 1
      }
    }
  ])

  cogs.turn("warm up") { c in c[temperature] = 80 }

  // The watch really ran, so history has a run to account for.
  #expect(alerts == 1)

  let effects = cogs.debugHistory.entries.filter { $0.event == .effect }
  // The given name composes beneath the mechanism's name.
  #expect(effects.contains { $0.name == "Weather.niceAlert" })
  // The run belongs to the turn that woke it, not to the install before it.
  #expect(effects.last?.name == "Weather.niceAlert")
  #expect(effects.last?.turn == 1)
}

@MainActor
@Test func `HIST-05 an unnamed registration lands under its file and line`() {
  let source = Cog<Int>.Manual(0)

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in _ = c[source] }
    }
  ])

  let effects = cogs.debugHistory.entries.filter { $0.event == .effect }
  #expect(effects.count == 1)
  // No `name:` was given, so the label falls back to the registration site.
  // This test only checks that the fallback belongs to this registration.
  #expect(effects.first?.name.contains("HIST01_02_03_05ScenarioTests.swift") == true)
}

@MainActor
@Test func `HIST-03 history is bounded and drops its oldest entries`() {
  let cogs = Cogs.forTesting()
  let capacity = cogs.debugHistory.capacity
  let extra = 8
  var highWaterMark = 0

  // Each of these turns writes nothing, so it records exactly one entry and
  // the arithmetic below is exact.
  for index in 0..<(capacity + extra) {
    cogs.turn("turn \(index)") { _ in }
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
