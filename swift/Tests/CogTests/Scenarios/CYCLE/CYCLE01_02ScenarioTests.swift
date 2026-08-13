import Cog
import CogTesting
import Testing

@MainActor
@Test func `CYCLE-01 a cog that reads itself fails and names itself`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      var accountBalance: Cog<Int>!
      accountBalance = Cog<Int>({ c in c[accountBalance] }, name: "account balance")
      _ = cogs.peek(accountBalance)
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
      let cogs = Cogs.forTesting()
      var subtotal: Cog<Int>!
      var tax: Cog<Int>!
      subtotal = Cog<Int>({ c in c[tax] }, name: "subtotal")
      tax = Cog<Int>({ c in c[subtotal] }, name: "tax")
      _ = cogs.peek(subtotal)
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
