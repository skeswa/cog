import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-15 async work runs on the MainActor by default`() async {
  let cogs = Cogs.forTesting()
  let (started, startedContinuation) = AsyncStream.makeStream(
    of: Void.self,
    bufferingPolicy: .bufferingNewest(1)
  )
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    .run {
      MainActor.preconditionIsolated("AsyncCog default work")
      startedContinuation.yield()
      return 42
    }
  }

  let token = cogs.run { c in _ = c[forecast] }
  var startedIterator = started.makeAsyncIterator()
  guard await startedIterator.next() != nil else {
    Issue.record("The async work ended before it started")
    return
  }

  withExtendedLifetime(token) {}
}
