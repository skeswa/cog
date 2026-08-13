import Cog
import CogTesting
import Testing

// Child processes isolate the fatal bootstrap trap. Their capture-free bodies
// start without an installed app context.

// MARK: - ONE-02

@MainActor
@Test func `ONE-02 a second app bootstrap traps with a message that survives release`() async {
  // `.failure` rather than a specific signal: a Swift trap is `brk` on arm64
  // and `ud2` on x86_64, which arrive as different signals, and the scenario
  // is about stopping, not about how the CPU spells stopping.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      Cogs.bootstrapApp()
      Cogs.bootstrapApp()
    }
  }

  // "A clear error" is half the promise, and the half a release build is most
  // likely to quietly drop: the standard library discards
  // `preconditionFailure`'s message under `-O`. Reading the child's stderr is
  // what makes this test fail if the guard ever regresses to a silent trap.
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog is already bootstrapped"))
  #expect(stderr.contains("Cogs.forTesting()"))
}
