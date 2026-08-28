import Cog
import CogTesting
import Testing

private nonisolated enum ControlledWorkFailure: Error, Equatable {
  case outage
}

@MainActor
@Test func `SEED-09 ControlledWork announces starts and completes exact generations`()
  async throws
{
  let cogs = Cogs.forTesting()
  let work = ControlledWork<Int>()
  let forecastCog = Cog<Int>.Async(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  var starts = work.starts.makeAsyncIterator()

  let initial = cogs.status.peek(forecastCog)
  #expect(initial.kind == .pending)
  #expect(await starts.next() == 0)

  // A completion for a generation that has not started is a documented no-op,
  // so a stale or mistyped generation cannot resolve the pending one.
  work.succeed(1, with: 999)
  #expect(cogs.status.peek(forecastCog).kind == .pending)

  try await resolveAsyncStatus(in: cogs) { work.succeed(0, with: 72) }
  let succeeded = cogs.status.peek(forecastCog)
  #expect(succeeded.kind == .success)
  #expect(succeeded.value == 72)

  _ = cogs.refresh(forecastCog)
  #expect(await starts.next() == 1)
  try await resolveAsyncStatus(in: cogs) {
    work.fail(1, with: ControlledWorkFailure.outage)
  }
  let failed = cogs.status.peek(forecastCog)
  #expect(failed.kind == .failure)
  #expect(failed.error as? ControlledWorkFailure == .outage)
  #expect(failed.value == 72)
}
