#if DEBUG

import Cog
import CogTesting
import Testing

// Seed's misuse guard is a debug-only trap: release builds have no seed at all
// (SEED-05), so both child processes here are debug children.

@MainActor
@Test func `SEED-08 seeding inside a commit body traps with a clear error`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let count = ManualCog<Int>(0, name: "count")

      cogs.commit { _ in
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
      let count = ManualCog<Int>(0, name: "count")
      let sneaky = Cog<Int> { c in
        cogs.seed(count, to: 7)
        return c[count]
      }

      _ = cogs.peek(sneaky)
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
