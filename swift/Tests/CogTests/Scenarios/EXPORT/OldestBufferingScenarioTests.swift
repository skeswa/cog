import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-04 oldest buffering preserves its first unseen values`() async {
  let phaseCog = Cog<String>.Manual { "initial" }
  let cogs = Cogs.forTesting()
  let values = cogs.values(of: phaseCog, buffering: .oldest(2))
  var iterator = values.makeAsyncIterator()

  #expect(await iterator.next() == "initial")

  var completedTurns: [String] = []
  for phase in ["A", "B", "C"] {
    cogs.turn(phaseCog, to: phase)
    completedTurns.append(phase)
  }

  #expect(completedTurns == ["A", "B", "C"])
  #expect(cogs.peek(phaseCog) == "C")
  #expect(await iterator.next() == "A")
  #expect(await iterator.next() == "B")

  cogs.turn(phaseCog, to: "D")
  #expect(await iterator.next() == "D")
}
