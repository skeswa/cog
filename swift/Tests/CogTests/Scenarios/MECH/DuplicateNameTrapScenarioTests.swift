import Cog
import CogTesting
import Testing

// The child process isolates the fatal duplicate-name trap. Its capture-free
// body builds both same-named mechanisms inline.

@MainActor
@Test func `MECH-04 two same-named mechanisms trap with a message that survives release`() async {
  // Check `.failure`, not a signal. Swift traps use `brk` on arm64 and `ud2` on
  // x86_64, but this scenario cares only that execution stops.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      _ = Cogs.forTesting(mechanisms: [
        MechanismProbe(name: "Twin") { _ in },
        MechanismProbe(name: "Twin") { _ in },
      ])
    }
  }

  // "A clear error" is half the promise, and the half a release build is most
  // likely to quietly drop: the standard library discards
  // `preconditionFailure`'s message under `-O`. Reading the child's stderr is
  // what makes this test fail if the guard ever regresses to a silent trap.
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Two mechanisms in one assembly list are both named \"Twin\""))
  #expect(stderr.contains("explicit `name`"))
}
