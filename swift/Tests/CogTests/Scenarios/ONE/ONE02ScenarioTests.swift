import Cog
import CogTesting
import Testing

// `ONE-02`, the second-install guard. Public `Cog` API and the `CogTesting`
// product only — no `@testable` (scenarios.md constraint 3).
//
// These are exit tests because the guard is a trap: an in-process `#expect`
// cannot survive one, and a trap taken in the suite's own process would take
// every other test down with it. Each exit test spawns a child process, so
// there are as few of them as the behavior allows (scenarios.md constraint 2)
// — one for the scenario, one for the seam it silently governs.
//
// The child process runs only the closure body, and the body captures nothing,
// so every install below happens in a process that has never bootstrapped.
// That is also why these tests need no cleanup: the polluted process exits.

// MARK: - ONE-02

@MainActor
@Test func `ONE-02 a second app bootstrap traps with a message that survives release`() async {
  // `.failure` rather than a specific signal: a Swift trap is `brk` on arm64
  // and `ud2` on x86_64, which arrive as different signals, and the scenario
  // is about stopping, not about how the CPU spells stopping.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      Cogtext.bootstrapApp()
      Cogtext.bootstrapApp()
    }
  }

  // "A clear error" is half the promise, and the half a release build is most
  // likely to quietly drop: the standard library discards
  // `preconditionFailure`'s message under `-O`. Reading the child's stderr is
  // what makes this test fail if the guard ever regresses to a silent trap.
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog is already bootstrapped"))
  #expect(stderr.contains("Cogtext.forTesting()"))
}
