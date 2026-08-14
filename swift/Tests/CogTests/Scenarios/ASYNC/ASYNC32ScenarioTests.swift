import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
private final class Async32ControlledWork {
  let starts: AsyncStream<Int>

  private let startContinuation: AsyncStream<Int>.Continuation
  private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]
  private var nextRun = 0

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

  func succeed(_ run: Int, with value: Int) {
    continuations.removeValue(forKey: run)?.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-32 the status lens carries tracked reads with value parity`() async {
  let cogs = Cogs.forTesting()
  let work = Async32ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)

  // A tracked selector-side status read demands the state exactly like a value
  // read would, and delivers every later status turn to its consumer.
  let token = cogs.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let initialPending = await statusIterator.next(),
    initialPending.kind == .pending, !initialPending.hasSucceeded
  else {
    Issue.record("The tracked status read did not begin at initial pending")
    return
  }
  #expect(await startIterator.next() == 0)

  // The UI-boundary lens and the one-shot lens read the same settled status,
  // and the plain value spellings beside them stay total.
  let uiStatus = cogs.status[forecast]
  if uiStatus.kind != .pending || uiStatus.hasSucceeded {
    Issue.record("The UI status lens did not read settled pending status")
  }
  let oneShotStatus = cogs.status.peek(forecast)
  if oneShotStatus.kind != .pending || oneShotStatus.hasSucceeded {
    Issue.record("The one-shot status lens did not read settled pending status")
  }
  #expect(cogs[forecast] == 0)
  #expect(cogs.peek(forecast) == 0)

  work.succeed(0, with: 42)
  guard let success = await statusIterator.next(),
    success.kind == .success, success.value == 42
  else {
    Issue.record("The tracked status read did not observe success")
    return
  }
  withExtendedLifetime(token) {}
}

@MainActor
@Test func `ASYNC-32 a status watch sees turns an equal-success value watch gates away`()
  async
{
  let cogs = Cogs.forTesting()
  let work = Async32ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let (statusEvents, statusContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  var valueEvents: [Int] = []

  let statusToken = cogs.status.watch(forecast, initial: .run, name: "watch.status") {
    _, new in
    statusContinuation.yield(new)
  }
  let valueToken = cogs.watch(forecast, initial: .run, name: "watch.value") { _, new in
    valueEvents.append(new)
  }
  var statusIterator = statusEvents.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let initialPending = await statusIterator.next(),
    initialPending.kind == .pending, !initialPending.hasSucceeded
  else {
    Issue.record("The status watch did not begin at initial pending")
    return
  }
  #expect(valueEvents == [0])
  #expect(await startIterator.next() == 0)

  work.succeed(0, with: 42)
  guard let firstSuccess = await statusIterator.next(),
    firstSuccess.kind == .success, firstSuccess.value == 42
  else {
    Issue.record("The status watch did not observe the first success")
    return
  }
  #expect(valueEvents == [0, 42])

  // An equal-success refresh cycles the full status — pending, then success —
  // while the value watch beside the lens stays quiet.
  cogs.refresh(forecast)
  guard let reloadPending = await statusIterator.next(),
    reloadPending.kind == .pending, reloadPending.value == 42, reloadPending.hasSucceeded
  else {
    Issue.record("The status watch did not observe reload pending")
    return
  }
  #expect(await startIterator.next() == 1)
  work.succeed(1, with: 42)
  guard let reloadSuccess = await statusIterator.next(),
    reloadSuccess.kind == .success, reloadSuccess.value == 42
  else {
    Issue.record("The status watch did not observe the equal reload success")
    return
  }
  #expect(valueEvents == [0, 42])

  withExtendedLifetime((statusToken, valueToken)) {}
}

@MainActor
@Test func `ASYNC-32 SwiftUI observes only the status fields its body reads`() async throws {
  let cogs = Cogs.forTesting()
  let work = Async32ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let kindNotices = OSAllocatedUnfairLock(initialState: 0)
  let valueNotices = OSAllocatedUnfairLock(initialState: 0)
  let successNotices = OSAllocatedUnfairLock(initialState: 0)
  let errorNotices = OSAllocatedUnfairLock(initialState: 0)
  let loadingNotices = OSAllocatedUnfairLock(initialState: 0)

  let initialKind = withObservationTracking {
    cogs.status[forecast].kind
  } onChange: {
    kindNotices.withLock { $0 += 1 }
  }
  let initialValue = withObservationTracking {
    cogs.status[forecast].value
  } onChange: {
    valueNotices.withLock { $0 += 1 }
  }
  let initiallySucceeded = withObservationTracking {
    cogs.status[forecast].hasSucceeded
  } onChange: {
    successNotices.withLock { $0 += 1 }
  }
  let initialError = withObservationTracking {
    cogs.status[forecast].error
  } onChange: {
    errorNotices.withLock { $0 += 1 }
  }
  let initiallyLoading = withObservationTracking {
    cogs.status[forecast].isLoading
  } onChange: {
    loadingNotices.withLock { $0 += 1 }
  }

  #expect(initialKind == .pending)
  #expect(initialValue == 0)
  #expect(!initiallySucceeded)
  #expect(initialError == nil)
  #expect(initiallyLoading)

  var startIterator = work.starts.makeAsyncIterator()
  #expect(await startIterator.next() == 0)
  let completionChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: completionChecked)
  work.succeed(0, with: 0)
  try await completionChecked.wait()

  #expect(kindNotices.withLock { $0 } == 1)
  #expect(valueNotices.withLock { $0 } == 0)
  #expect(successNotices.withLock { $0 } == 1)
  #expect(errorNotices.withLock { $0 } == 0)
  #expect(loadingNotices.withLock { $0 } == 1)
}
