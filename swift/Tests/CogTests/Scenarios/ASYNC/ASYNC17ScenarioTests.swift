import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-17 async task name includes its descriptor and key`() async {
  let cogs = Cogtext.forTesting()
  let forecast = AsyncCog<String?>(name: "forecast") { _ in
    .run { CogTaskDiagnostic.currentTaskName }
  }
  let keyedForecast = forecast.taskNameDiagnosticReference(for: 90_210)
  let (phases, continuation) = AsyncStream.makeStream(of: CogPhase<String?>.self)
  let token = cogs.run { c in continuation.yield(c[keyedForecast]) }
  var iterator = phases.makeAsyncIterator()

  guard await iterator.next() != nil else {
    Issue.record("The phase stream ended before pending")
    return
  }
  guard let completed = await iterator.next() else {
    Issue.record("The phase stream ended before success")
    return
  }

  switch completed {
  case .success(let taskName):
    #expect(taskName == "forecast[90210]")
  default:
    Issue.record("Expected work to return its runtime task name")
  }
  withExtendedLifetime(token) {}
}
