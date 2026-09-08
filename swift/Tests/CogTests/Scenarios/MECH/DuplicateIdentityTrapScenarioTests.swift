import Cog
import CogTesting
import Testing

// A collection scope owns one lifetime per identity. Two entries sharing an
// identity describe two lifetimes that cannot be told apart, so reconciliation
// refuses rather than quietly serving both from one child.

@MainActor
@Test func `MECH-33 a duplicate identity in a collection scope traps`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let openEntries = Cog<[Int]>.Manual { [] }
      let cogs = Cogs.forTesting(mechanisms: [
        MechanismProbe { m in
          m.scope(each: openEntries, name: "entry") { _, _ in }
        }
      ])
      cogs.turn(openEntries, to: [7, 9, 7])
    }
  }

  let message = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(message.contains("Probe.entry"), "stderr was: \(message)")
  #expect(message.contains("twice in one collection"), "stderr was: \(message)")
  #expect(message.contains("distinct identity"), "stderr was: \(message)")
}
