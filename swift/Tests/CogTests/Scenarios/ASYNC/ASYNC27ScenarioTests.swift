import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-27 refresh cannot run during an async selector`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let target = Cog<Int>.Async(default: 0, name: "target") { _ in
        fatalError("REFRESH TARGET SELECTOR RAN")
      }
      let refreshing = Cog<Int>.Async(default: 0, name: "refreshing") { _ in
        cogs.refresh(target)
        fatalError("REFRESHING SELECTOR CONTINUED")
      }

      _ = cogs.peek(refreshing)
    }
  }

  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(
    stderr.contains("Cog cannot start turn \(String(reflecting: "refresh(_:)"))"),
    "stderr was: \(stderr)"
  )
  #expect(stderr.contains("automatic cog refreshing is computing"), "stderr was: \(stderr)")
  #expect(stderr.contains("Automatic computation may only read Cog state"), "stderr was: \(stderr)")
  #expect(
    stderr.contains(
      "Invoke this op outside automatic computation, from event handling or a reaction."
    ),
    "stderr was: \(stderr)"
  )
  #expect(!stderr.contains("REFRESH TARGET SELECTOR RAN"), "stderr was: \(stderr)")
  #expect(!stderr.contains("REFRESHING SELECTOR CONTINUED"), "stderr was: \(stderr)")
}
