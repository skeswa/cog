import Cog
import CogTesting
import Testing

@MainActor
@Test func `EXPORT-04 oldest buffering preserves its first unseen values`() async {
  let phaseCog = ManualCog<String>("initial")
  let cogs = Cogs.forTesting()
  let values = cogs.values(of: phaseCog, buffering: .oldest(2))
  var iterator = values.makeAsyncIterator()

  #expect(await iterator.next() == "initial")

  var completedCommits: [String] = []
  for phase in ["A", "B", "C"] {
    cogs.commit(phaseCog, to: phase)
    completedCommits.append(phase)
  }

  #expect(completedCommits == ["A", "B", "C"])
  #expect(cogs.peek(phaseCog) == "C")
  #expect(await iterator.next() == "A")
  #expect(await iterator.next() == "B")

  cogs.commit(phaseCog, to: "D")
  #expect(await iterator.next() == "D")
}
