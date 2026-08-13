import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-27 refresh cannot run during an async selector`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogtext.forTesting()
      let target = AsyncCog<Int>(name: "target") { _ in
        fatalError("REFRESH TARGET SELECTOR RAN")
      }
      let refreshing = AsyncCog<Int>(name: "refreshing") { _ in
        cogs.refresh(target)
        fatalError("REFRESHING SELECTOR CONTINUED")
      }

      _ = cogs.peek(refreshing)
    }
  }

  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(
    stderr.contains("Cog cannot commit turn \(String(reflecting: "refresh(_:)"))"),
    "stderr was: \(stderr)"
  )
  #expect(stderr.contains("derived cog refreshing is computing"), "stderr was: \(stderr)")
  #expect(stderr.contains("Derived computation may only read Cog state"), "stderr was: \(stderr)")
  #expect(
    stderr.contains(
      "Invoke this op outside derived computation, from event handling or a reaction."
    ),
    "stderr was: \(stderr)"
  )
  #expect(!stderr.contains("REFRESH TARGET SELECTOR RAN"), "stderr was: \(stderr)")
  #expect(!stderr.contains("REFRESHING SELECTOR CONTINUED"), "stderr was: \(stderr)")
}
