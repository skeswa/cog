import Cog
import CogTesting
import Testing

// ASYNC-30 owns the whole §5.1 accessor set over one lifecycle walk: every
// accessor at every visible state — the retired ASYNC-04, which described the
// same set over the same walk — plus the current-generation semantics of
// `value` and `error`: a retry's pending clears the failure while the
// renderable value survives.

private nonisolated enum Async04Error: Error, Equatable {
  case offline
}

@MainActor
@Test func `ASYNC-30 status accessors describe every request state`() async throws {
  let cogs = Cogs.forTesting()
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0) { _ in work.makeWork() }
  var starts = work.starts.makeAsyncIterator()

  let initialPending = cogs.status.peek(forecast)
  #expect(initialPending.kind == .pending)
  #expect(initialPending.value == 0)
  #expect(!initialPending.hasSucceeded)
  #expect(initialPending.error == nil)
  #expect(initialPending.isLoading)

  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) {
    work.fail(0, with: Async04Error.offline)
  }
  let initialFailure = cogs.status.peek(forecast)
  #expect(initialFailure.kind == .failure)
  #expect(initialFailure.value == 0)
  #expect(!initialFailure.hasSucceeded)
  #expect(initialFailure.error as? Async04Error == .offline)
  #expect(!initialFailure.isLoading)

  // A retry after a failure is loading again with no error: `error` reports
  // only the current failure, while `value` stays renderable through it.
  cogs.refresh(forecast)
  let retryPending = cogs.status.peek(forecast)
  #expect(retryPending.kind == .pending)
  #expect(retryPending.value == 0)
  #expect(!retryPending.hasSucceeded)
  #expect(retryPending.error == nil)
  #expect(retryPending.isLoading)

  #expect(await starts.next() == 1)
  try await resolveAsyncStatus(in: cogs) {
    work.succeed(1, with: 42)
  }
  let success = cogs.status.peek(forecast)
  #expect(success.kind == .success)
  #expect(success.value == 42)
  #expect(success.hasSucceeded)
  #expect(success.error == nil)
  #expect(!success.isLoading)

  cogs.refresh(forecast)
  let reloadPending = cogs.status.peek(forecast)
  #expect(reloadPending.kind == .pending)
  #expect(reloadPending.value == 42)
  #expect(reloadPending.hasSucceeded)
  #expect(reloadPending.error == nil)
  #expect(reloadPending.isLoading)

  #expect(await starts.next() == 2)
  try await resolveAsyncStatus(in: cogs) {
    work.fail(2, with: Async04Error.offline)
  }
  let reloadFailure = cogs.status.peek(forecast)
  #expect(reloadFailure.kind == .failure)
  #expect(reloadFailure.value == 42)
  #expect(reloadFailure.hasSucceeded)
  #expect(reloadFailure.error as? Async04Error == .offline)
  #expect(!reloadFailure.isLoading)
}

@MainActor
@Test func `ASYNC-30 hasSucceeded distinguishes a default nil from a successful nil`()
  async throws
{
  let cogs = Cogs.forTesting()
  let work = ControlledWork<Int?>()
  let forecast = Cog<Int?>.Async(default: nil) { _ in work.makeWork() }
  var starts = work.starts.makeAsyncIterator()

  let defaultNil = cogs.status.peek(forecast)
  #expect(defaultNil.kind == .pending)
  #expect(defaultNil.value == nil)
  #expect(!defaultNil.hasSucceeded)

  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) {
    work.succeed(0, with: nil)
  }
  let successfulNil = cogs.status.peek(forecast)
  #expect(successfulNil.kind == .success)
  #expect(successfulNil.value == nil)
  #expect(successfulNil.hasSucceeded)

  cogs.refresh(forecast)
  let reloadAfterNil = cogs.status.peek(forecast)
  #expect(reloadAfterNil.kind == .pending)
  #expect(reloadAfterNil.value == nil)
  #expect(reloadAfterNil.hasSucceeded)
  #expect(reloadAfterNil.isLoading)
}
