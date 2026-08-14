import Cog
import CogTesting
import Testing

private nonisolated enum Async30Error: Error, Equatable {
  case offline
}

@MainActor
@Test func `ASYNC-30 value and error describe the current generation`() async throws {
  let cogs = Cogs.forTesting()
  let work = AsyncStatusControlledWork<Int>()
  let forecast = AsyncCog<Int>(default: 0) { _ in work.makeWork() }
  var starts = work.starts.makeAsyncIterator()

  let initialPending = cogs.status.peek(forecast)
  #expect(initialPending.value == 0)
  #expect(initialPending.error == nil)

  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) {
    work.fail(0, with: Async30Error.offline)
  }
  let initialFailure = cogs.status.peek(forecast)
  #expect(initialFailure.value == 0)
  #expect(initialFailure.error as? Async30Error == .offline)

  cogs.refresh(forecast)
  let retryPending = cogs.status.peek(forecast)
  #expect(retryPending.value == 0)
  #expect(retryPending.error == nil)

  #expect(await starts.next() == 1)
  try await resolveAsyncStatus(in: cogs) {
    work.succeed(1, with: 42)
  }
  let success = cogs.status.peek(forecast)
  #expect(success.value == 42)
  #expect(success.error == nil)

  cogs.refresh(forecast)
  let reloadPending = cogs.status.peek(forecast)
  #expect(reloadPending.value == 42)
  #expect(reloadPending.error == nil)

  #expect(await starts.next() == 2)
  try await resolveAsyncStatus(in: cogs) {
    work.fail(2, with: Async30Error.offline)
  }
  let reloadFailure = cogs.status.peek(forecast)
  #expect(reloadFailure.value == 42)
  #expect(reloadFailure.error as? Async30Error == .offline)
}

@MainActor
@Test func `ASYNC-30 loading and success stay orthogonal`() async throws {
  let cogs = Cogs.forTesting()
  let work = AsyncStatusControlledWork<Int>()
  let forecast = AsyncCog<Int>(default: 0) { _ in work.makeWork() }
  var starts = work.starts.makeAsyncIterator()

  let initialPending = cogs.status.peek(forecast)
  #expect(initialPending.kind == .pending)
  #expect(initialPending.isLoading)
  #expect(!initialPending.hasSucceeded)

  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) {
    work.fail(0, with: Async30Error.offline)
  }
  let initialFailure = cogs.status.peek(forecast)
  #expect(initialFailure.kind == .failure)
  #expect(!initialFailure.isLoading)
  #expect(!initialFailure.hasSucceeded)

  cogs.refresh(forecast)
  #expect(await starts.next() == 1)
  try await resolveAsyncStatus(in: cogs) {
    work.succeed(1, with: 42)
  }
  let success = cogs.status.peek(forecast)
  #expect(success.kind == .success)
  #expect(!success.isLoading)
  #expect(success.hasSucceeded)

  cogs.refresh(forecast)
  let reloadPending = cogs.status.peek(forecast)
  #expect(reloadPending.kind == .pending)
  #expect(reloadPending.isLoading)
  #expect(reloadPending.hasSucceeded)

  #expect(await starts.next() == 2)
  try await resolveAsyncStatus(in: cogs) {
    work.fail(2, with: Async30Error.offline)
  }
  let reloadFailure = cogs.status.peek(forecast)
  #expect(reloadFailure.kind == .failure)
  #expect(!reloadFailure.isLoading)
  #expect(reloadFailure.hasSucceeded)
}

@MainActor
@Test func `ASYNC-30 a successful nil stays distinct through value`() async throws {
  let cogs = Cogs.forTesting()
  let work = AsyncStatusControlledWork<Int?>()
  let forecast = AsyncCog<Int?>(default: nil) { _ in work.makeWork() }
  var starts = work.starts.makeAsyncIterator()

  _ = cogs.status.peek(forecast)
  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) {
    work.succeed(0, with: nil)
  }
  let successNil = cogs.status.peek(forecast)
  #expect(successNil.kind == .success)
  #expect(successNil.value == nil)
  #expect(successNil.hasSucceeded)

  cogs.refresh(forecast)
  let reloadAfterNil = cogs.status.peek(forecast)
  #expect(reloadAfterNil.kind == .pending)
  #expect(reloadAfterNil.value == nil)
  #expect(reloadAfterNil.hasSucceeded)
  #expect(reloadAfterNil.isLoading)
}
