import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-17 async task name includes its descriptor and key`() async {
  let (cogs, m) = Cogs.forTestingWithController()
  let forecast = CogBox<String?, Int>.Async(default: nil, name: "forecast") { _, _ in
    .run { CogTaskDiagnostic.currentTaskName }
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<String?>.self)
  m.run { c in continuation.yield(c.status[forecast[90_210]]) }
  var iterator = statuses.makeAsyncIterator()

  guard await iterator.next() != nil else {
    Issue.record("The status stream ended before pending")
    return
  }
  guard let completed = await iterator.next() else {
    Issue.record("The status stream ended before success")
    return
  }

  if completed.kind == .success {
    #expect(completed.value == "forecast[90210]")
  } else {
    Issue.record("Expected work to return its runtime task name")
  }
}
