import Cog
import CogTesting
import Testing

@MainActor
private final class Async10ControlledWork {
  let starts: AsyncStream<Int>

  private let startContinuation: AsyncStream<Int>.Continuation
  private var nextRun = 0
  private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func makeWork() -> Work<Int> {
    let run = nextRun
    nextRun += 1
    return .run {
      self.startContinuation.yield(run)
      return await withCheckedContinuation { self.continuations[run] = $0 }
    }
  }

  func finish(_ run: Int, with value: Int) {
    continuations.removeValue(forKey: run)?.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-10 refresh cycles a settled async cog again`() async {
  let (cogs, m) = probedContext()
  let work = Async10ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in work.makeWork() }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  _ = await statusIterator.next()
  #expect(await startIterator.next() == 0)
  work.finish(0, with: 10)
  _ = await statusIterator.next()

  let refresh = cogs.refresh(forecast)
  guard let reload = await statusIterator.next() else {
    Issue.record("The status stream ended before refresh pending")
    return
  }
  if reload.kind == .pending, reload.hasSucceeded {
    #expect(reload.value == 10)
  } else {
    Issue.record("Expected refresh pending with the settled value")
  }
  #expect(await startIterator.next() == 1)
  work.finish(1, with: 20)

  guard let success = await statusIterator.next() else {
    Issue.record("The status stream ended before refreshed success")
    return
  }
  if success.kind == .success {
    #expect(success.value == 20)
  } else {
    Issue.record("Expected refreshed success")
  }
  if case .success(let value) = await refresh.outcome {
    #expect(value == 20)
  } else {
    Issue.record("The refresh handle did not complete with its exact success")
  }
}

@MainActor
@Test func `ASYNC-21 refresh replaces in-flight latest work`() async throws {
  let (cogs, m) = probedContext()
  let work = Async10ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in work.makeWork() }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  _ = await statusIterator.next()
  #expect(await startIterator.next() == 0)
  let supersededRefresh = cogs.refresh(forecast)
  guard let replacementPending = await statusIterator.next() else {
    Issue.record("The status stream ended before replacement pending")
    return
  }
  if replacementPending.kind != .pending || replacementPending.hasSucceeded {
    Issue.record("Expected in-flight refresh pending without a previous value")
  }
  #expect(await startIterator.next() == 1)

  let newestRefresh = cogs.refresh(forecast)
  guard let newestPending = await statusIterator.next() else {
    Issue.record("The status stream ended before newest pending")
    return
  }
  if newestPending.kind != .pending || newestPending.hasSucceeded {
    Issue.record("Expected the newest refresh to remain initial pending")
  }
  #expect(await startIterator.next() == 2)
  if case .superseded = await supersededRefresh.outcome {
  } else {
    Issue.record("The replaced refresh handle did not resolve as superseded")
  }

  let staleChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: staleChecked)
  work.finish(0, with: 100)
  try await staleChecked.wait()
  let statusAfterStaleCompletion = cogs.status.peek(forecast)
  if statusAfterStaleCompletion.kind != .pending || statusAfterStaleCompletion.hasSucceeded {
    Issue.record("The replaced run published after refresh")
  }

  let replacedChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: replacedChecked)
  work.finish(1, with: 150)
  try await replacedChecked.wait()

  work.finish(2, with: 200)
  guard let success = await statusIterator.next() else {
    Issue.record("The status stream ended before replacement success")
    return
  }
  if success.kind == .success {
    #expect(success.value == 200)
  } else {
    Issue.record("Expected only refreshed work to turn")
  }
  if case .success(let value) = await newestRefresh.outcome {
    #expect(value == 200)
  } else {
    Issue.record("The newest refresh handle did not complete with success")
  }
}
