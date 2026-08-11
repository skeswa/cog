import Cog
import CogTesting
import Testing

// `TURN-07`, the escaped writer. Public `Cog` API only — smuggling a writer out
// of its commit is something ordinary user code can do, so proving that Cog
// stops it needs no privileged surface at all (scenarios.md constraint 3).
//
// These are exit tests because the guard is a trap: it has to hold in shipping
// builds, so it cannot be an `assert` and it cannot be caught. Each one spawns
// a child process, which is why there are exactly two — one for each direction
// the writer's subscript can be used — and no third for the async variant of
// the same escape, which reaches the identical guard by the identical route
// (constraint 2).
//
// Both run in the debug legs and again in the release-configuration leg, which
// is where "in every kind of build" is actually proven: `assert` would still
// pass the debug run here and vanish in release.

@MainActor
@Test func `TURN-07 writing through a writer that outlived its commit traps`() async {
  // `.failure` rather than a named signal: the scenario is about being stopped,
  // not about how a given CPU spells a trap.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      let count = ManualCog<Int>(0, name: "count")

      var escaped: Writer?
      cogs.commit { w in
        escaped = w
      }

      escaped![count] = 1
    }
  }

  expectEscapedWriterMessage(in: result, mentioning: "writing to count")
}

@MainActor
@Test func `TURN-07 reading through a writer that outlived its commit traps`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      let count = ManualCog<Int>(0, name: "count")

      var escaped: Writer?
      cogs.commit { w in
        w[count] = 1
        escaped = w
      }

      // A writer read means "what this turn staged." Once the turn is over
      // there is no such value, and quietly answering with the committed one
      // would be a plausible wrong answer rather than an error.
      _ = escaped![count]
    }
  }

  expectEscapedWriterMessage(in: result, mentioning: "reading count")
}

// MARK: - The message

/// Checks that the trap said the two things the trap's own file and line
/// cannot: that the writer outlived its commit, and that the way to write now
/// is another `commit`.
///
/// Asserted in every configuration on purpose, release included. A guard whose
/// message only survives in debug is half a guard, and this is exactly the
/// property that breaks quietly: an optimized `preconditionFailure` carrying a
/// composed message prints raw bytes where the sentence should be, and nothing
/// but a release run would ever notice.
private func expectEscapedWriterMessage(
  in result: ExitTest.Result?,
  mentioning attempt: String
) {
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)

  #expect(stderr.contains("outlived the commit that created it"), "stderr was: \(stderr)")
  #expect(stderr.contains(attempt), "stderr was: \(stderr)")
  #expect(stderr.contains("call commit again"), "stderr was: \(stderr)")
}
