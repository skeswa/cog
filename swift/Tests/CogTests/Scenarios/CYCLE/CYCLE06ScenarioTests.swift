import Cog
import CogTesting
import Testing

@MainActor
@Test func `CYCLE-06 a keyed selector cannot start a turn`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let weather = CogBox<Int, String>(
        { _, _ in
          cogs.turn("illegal selector turn") { _ in
            fatalError("SELECTOR TURN BODY RAN")
          }
          return 0
        },
        name: "weather"
      )

      _ = cogs.peek(weather["home"])
    }
  }

  expectAutomaticTurnFailure(
    in: result,
    cog: "weather[home]",
    turn: "illegal selector turn",
    forbiddenBodyMarker: "SELECTOR TURN BODY RAN"
  )
}

@MainActor
@Test func `CYCLE-06 custom equality cannot start a turn before publication`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let source = Cog<Int>.Manual(0)
      let weather = CogBox<Int, String>(
        { c, _ in c[source] },
        equals: { _, _ in
          cogs.turn("illegal equality turn") { _ in
            fatalError("EQUALITY TURN BODY RAN")
          }
          return false
        },
        name: "weather"
      )

      _ = cogs.peek(weather["home"])
      cogs.turn { c in c[source] = 1 }
      _ = cogs.peek(weather["home"])
    }
  }

  expectAutomaticTurnFailure(
    in: result,
    cog: "weather[home]",
    turn: "illegal equality turn",
    forbiddenBodyMarker: "EQUALITY TURN BODY RAN"
  )
}

private func expectAutomaticTurnFailure(
  in result: ExitTest.Result?,
  cog: String,
  turn: String,
  forbiddenBodyMarker: String
) {
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(
    stderr.contains("Cog cannot start turn \(String(reflecting: turn))"), "stderr was: \(stderr)")
  #expect(stderr.contains("automatic cog \(cog) is computing"), "stderr was: \(stderr)")
  #expect(stderr.contains("Automatic computation may only read Cog state"), "stderr was: \(stderr)")
  #expect(
    stderr.contains(
      "Invoke this op outside automatic computation, from event handling or a reaction."
    ),
    "stderr was: \(stderr)"
  )
  #expect(!stderr.contains(forbiddenBodyMarker), "stderr was: \(stderr)")
}
