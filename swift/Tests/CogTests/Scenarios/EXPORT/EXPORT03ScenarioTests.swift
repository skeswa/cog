import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-03 default buffering keeps the newest value without blocking turns`() async {
  let phaseCog = Cog<String>.Manual("initial")
  let cogs = Cogs.forTesting()
  let values = cogs.values(of: phaseCog)
  var iterator = values.makeAsyncIterator()

  #expect(await iterator.next() == "initial")

  var completedTurns: [String] = []
  for phase in ["A", "B", "C"] {
    cogs.turn(phaseCog, to: phase)
    completedTurns.append(phase)
  }

  #expect(completedTurns == ["A", "B", "C"])
  #expect(cogs.peek(phaseCog) == "C")
  #expect(await iterator.next() == "C")
}
