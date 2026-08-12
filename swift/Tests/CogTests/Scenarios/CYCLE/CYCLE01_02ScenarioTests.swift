import Cog
import CogTesting
import Testing

@MainActor
@Test func `CYCLE-01 a cog that reads itself fails and names itself`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      var accountBalance: Cog<Int>!
      accountBalance = Cog<Int>({ c in c.get(accountBalance) }, name: "account balance")
      _ = cogs.read(accountBalance)
    }
  }

  expectPublicCycleMessage(
    in: result,
    path: "account balance -> account balance"
  )
}

@MainActor
@Test func `CYCLE-02 a multi cog cycle fails with its whole closed path`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      var subtotal: Cog<Int>!
      var tax: Cog<Int>!
      subtotal = Cog<Int>({ c in c.get(tax) }, name: "subtotal")
      tax = Cog<Int>({ c in c.get(subtotal) }, name: "tax")
      _ = cogs.read(subtotal)
    }
  }

  expectPublicCycleMessage(
    in: result,
    path: "subtotal -> tax -> subtotal"
  )
}

private func expectPublicCycleMessage(in result: ExitTest.Result?, path: String) {
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog dependency cycle"), "stderr was: \(stderr)")
  #expect(stderr.contains(path), "stderr was: \(stderr)")
}
