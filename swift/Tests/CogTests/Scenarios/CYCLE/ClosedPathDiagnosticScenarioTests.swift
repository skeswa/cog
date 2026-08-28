import Cog
import CogTesting
import Testing

@MainActor
@Test func `CYCLE-02 a multi cog cycle fails with its whole closed path`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      var subtotal: Cog<Int>!
      var tax: Cog<Int>!
      subtotal = Cog<Int>({ c in c[tax] }, name: "subtotal")
      tax = Cog<Int>({ c in c[subtotal] }, name: "tax")
      _ = cogs.peek(subtotal)
    }
  }

  // The self-loop (the retired CYCLE-01) is the one-link case of this same
  // walk and path formatter, so the closed two-cog path subsumes it.
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog dependency cycle"), "stderr was: \(stderr)")
  #expect(stderr.contains("subtotal -> tax -> subtotal"), "stderr was: \(stderr)")
}
