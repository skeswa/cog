import Cog
import CogTesting
import Testing

private actor ReactionTokenDropper {
  private var token: ReactionToken?

  init(token: consuming ReactionToken) {
    self.token = token
  }

  func drop() {
    self.preconditionIsolated()
    token = nil
  }
}

@MainActor
@Test func `REACT-18 background token release acknowledges MainActor cleanup`() async throws {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c[source])
  }
  let cleanup = MainActorCleanupAcknowledgement()
  token.acknowledgeDeinitCleanup(with: cleanup)
  #expect(!cleanup.hasBeenAcknowledged)
  let dropper = ReactionTokenDropper(token: consume token)

  let release = Task {
    await dropper.drop()
  }
  try await cleanup.wait()
  #expect(cleanup.hasBeenAcknowledged)

  cogs.commit { c in c[source] = 1 }
  #expect(seen == [0])
  #expect(cogs.peek(source) == 1)
  await release.value
}
