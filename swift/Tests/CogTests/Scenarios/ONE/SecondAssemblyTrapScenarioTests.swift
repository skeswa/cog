import Cog
import CogTesting
import Testing

// Child processes isolate the fatal assembly trap. Their capture-free bodies
// start without an installed app context.

// MARK: - ONE-02

@MainActor
@Test func `ONE-02 a second app assembly traps with a message that survives release`() async {
  // Check `.failure`, not a signal. Swift traps use `brk` on arm64 and `ud2` on
  // x86_64, but this scenario cares only that execution stops.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      Cogs.assemble()
      Cogs.assemble()
    }
  }

  // "A clear error" is half the promise, and the half a release build is most
  // likely to quietly drop: the standard library discards
  // `preconditionFailure`'s message under `-O`. Reading the child's stderr is
  // what makes this test fail if the guard ever regresses to a silent trap.
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog is already assembled"))
  #expect(stderr.contains("Cogs.forTesting(seeding:mechanisms:)"))
}
