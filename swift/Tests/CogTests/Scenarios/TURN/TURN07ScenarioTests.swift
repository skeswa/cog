import Cog
import CogTesting
import Testing

// Child processes prove that escaped writer reads and writes trap with a useful
// message in debug and release builds.

@MainActor
@Test func `TURN-07 writing through a writer that outlived its commit traps`() async {
  // `.failure` rather than a named signal: the scenario is about being stopped,
  // not about how a given CPU spells a trap.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let count = ManualCog<Int>(0, name: "count")

      var escaped: Writer?
      cogs.commit { c in
        escaped = c
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
      let cogs = Cogs.forTesting()
      let count = ManualCog<Int>(0, name: "count")

      var escaped: Writer?
      cogs.commit { c in
        c[count] = 1
        escaped = c
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
