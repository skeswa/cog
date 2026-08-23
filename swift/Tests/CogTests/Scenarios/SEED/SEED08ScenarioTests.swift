#if DEBUG

import Cog
import CogTesting
import Testing

// Seed's misuse guard is a debug-only trap: release builds have no seed at all
// (SEED-05), so every child process here is a debug child.

@MainActor
@Test func `SEED-08 seeding inside a turn body traps with a clear error`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let count = Cog<Int>.Manual(0, name: "count")

      cogs.turn { _ in
        cogs.seed(count, to: 7)
      }
    }
  }

  expectSeedMisuseMessage(in: result)
}

@MainActor
@Test func `SEED-08 seeding from a selector traps with a clear error`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let count = Cog<Int>.Manual(0, name: "count")
      let sneaky = Cog<Int> { c in
        cogs.seed(count, to: 7)
        return c[count]
      }

      _ = cogs.peek(sneaky)
    }
  }

  expectSeedMisuseMessage(in: result)
}

@MainActor
@Test func `SEED-08 seeding from a reaction traps with a clear error`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let count = Cog<Int>.Manual(0, name: "count")

      // The reaction stays quiet through its assembly run (count is still 0
      // and the context reference is still nil) and seeds only when the turn
      // below wakes it, so the trap fires mid-flush — a different re-entrancy
      // point than the mid-turn and mid-settle children above.
      var cogs: Cogs?
      cogs = Cogs.forTesting(mechanisms: [
        MechanismProbe { m in
          m.run { c in
            guard c[count] == 1, let cogs else { return }
            cogs.seed(count, to: 7)
          }
        }
      ])

      cogs?.turn("wake") { c in c[count] = 1 }
    }
  }

  expectSeedMisuseMessage(in: result)
}

/// Checks that the trap said what its own file and line cannot: that seed is
/// only for idle test setup, so the fix is to move it, not to retry it.
private func expectSeedMisuseMessage(in result: ExitTest.Result?) {
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("seed"), "stderr was: \(stderr)")
  #expect(stderr.contains("idle test setup"), "stderr was: \(stderr)")
}

#endif
