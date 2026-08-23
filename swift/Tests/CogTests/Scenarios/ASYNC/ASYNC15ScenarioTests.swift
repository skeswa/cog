import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-15 async work runs on the MainActor by default`() async {
  let (cogs, m) = probedContext()
  let (started, startedContinuation) = AsyncStream.makeStream(
    of: Void.self,
    bufferingPolicy: .bufferingNewest(1)
  )
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { _ in
    .run {
      MainActor.preconditionIsolated("Cog.Async default work")
      startedContinuation.yield()
      return 42
    }
  }

  m.run { c in _ = c[forecast] }
  var startedIterator = started.makeAsyncIterator()
  guard await startedIterator.next() != nil else {
    Issue.record("The async work ended before it started")
    return
  }

}
