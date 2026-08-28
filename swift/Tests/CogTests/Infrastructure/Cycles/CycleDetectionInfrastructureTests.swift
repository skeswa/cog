import CogTesting
import Testing

@testable import Cog

// These internal checks cover arena computation paths. Scenario tests use the
// CogTesting diagnostic and child processes to cover public failures: the
// cold keyed trap is CYCLE-07's proof, so the only child process here is the
// warm one. It traps during explicit-stack re-entry, a settlement path that no
// public scenario drives through the real trap.

@MainActor
@Test func `CycleDetectionInfrastructure catches a warm cycle at explicit stack entry`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let closesCycle = Cog<Bool>.Manual { false }
      var first: Cog<Int>!
      var second: Cog<Int>!
      first = Cog<Int>(
        { c in c[closesCycle] ? c[second] : 1 },
        name: "first"
      )
      second = Cog<Int>({ c in c[first] + 1 }, name: "second")

      _ = cogs.peek(second)
      cogs.turn { c in c[closesCycle] = true }
      _ = cogs.peek(first)
    }
  }

  expectCycleMessage(in: result, path: "first -> second -> first")
}

@MainActor
@Test func `CycleDetectionInfrastructure nested settlement preserves outer frames`() {
  let cogs = Cogs.forTesting()
  let switcher = Cog<Bool>.Manual { false }
  let rightSource = Cog<Int>.Manual { 10 }
  let lateSource = Cog<Int>.Manual { 100 }
  var leftRuns = 0
  var rightRuns = 0
  var rootRuns = 0

  let late = Cog<Int> { c in c[lateSource] }
  let left = Cog<Int> { c in
    leftRuns += 1
    return c[switcher] ? c[late] : 1
  }
  let right = Cog<Int> { c in
    rightRuns += 1
    return c[rightSource]
  }
  let root = Cog<Int> { c in
    rootRuns += 1
    return c[left] + c[right]
  }

  #expect(cogs.peek(root) == 11)
  #expect(cogs.peek(late) == 100)

  cogs.turn { c in
    c[switcher] = true
    c[rightSource] = 20
    c[lateSource] = 200
  }

  #expect(cogs.peek(root) == 220)
  #expect(leftRuns == 2)
  #expect(rightRuns == 2)
  #expect(rootRuns == 2)
  #expect(cogs.arenaCore.isSettlementIdle)
}

private func expectCycleMessage(in result: ExitTest.Result?, path: String) {
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog dependency cycle"), "stderr was: \(stderr)")
  #expect(stderr.contains(path), "stderr was: \(stderr)")
}
