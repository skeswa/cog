import Cog
import CogTesting
import Testing

@MainActor
@Test func `CYCLE-06 a keyed selector cannot commit`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      let weather = CogBox<Int, String>(
        { _, _ in
          cogs.commit("illegal selector turn") { _ in
            fatalError("SELECTOR COMMIT BODY RAN")
          }
          return 0
        },
        name: "weather"
      )

      _ = cogs.peek(weather["home"])
    }
  }

  expectDerivedCommitFailure(
    in: result,
    cog: "weather[home]",
    turn: "illegal selector turn",
    forbiddenBodyMarker: "SELECTOR COMMIT BODY RAN"
  )
}

@MainActor
@Test func `CYCLE-06 custom equality cannot commit before publication`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      let source = ManualCog<Int>(0)
      let weather = CogBox<Int, String>(
        { c, _ in c[source] },
        equals: { _, _ in
          cogs.commit("illegal equality turn") { _ in
            fatalError("EQUALITY COMMIT BODY RAN")
          }
          return false
        },
        name: "weather"
      )

      _ = cogs.peek(weather["home"])
      cogs.commit { c in c[source] = 1 }
      _ = cogs.peek(weather["home"])
    }
  }

  expectDerivedCommitFailure(
    in: result,
    cog: "weather[home]",
    turn: "illegal equality turn",
    forbiddenBodyMarker: "EQUALITY COMMIT BODY RAN"
  )
}

private func expectDerivedCommitFailure(
  in result: ExitTest.Result?,
  cog: String,
  turn: String,
  forbiddenBodyMarker: String
) {
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(
    stderr.contains("Cog cannot commit turn \(String(reflecting: turn))"), "stderr was: \(stderr)")
  #expect(stderr.contains("derived cog \(cog) is computing"), "stderr was: \(stderr)")
  #expect(stderr.contains("Derived computation may only read Cog state"), "stderr was: \(stderr)")
  #expect(
    stderr.contains(
      "Invoke this op outside derived computation, from event handling or a reaction."
    ),
    "stderr was: \(stderr)"
  )
  #expect(!stderr.contains(forbiddenBodyMarker), "stderr was: \(stderr)")
}
