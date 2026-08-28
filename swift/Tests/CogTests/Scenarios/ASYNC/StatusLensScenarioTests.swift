import Cog
import CogTesting
import Observation
import Testing
import os

@MainActor
@Test func `ASYNC-01 ASYNC-32 the status lens carries tracked reads with value parity`() async {
  let (cogs, m) = Cogs.forTestingWithController()
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)

  // A tracked selector-side status read demands the state exactly like a value
  // read would, and delivers every later status turn to its consumer.
  m.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let initialPending = await statusIterator.next(),
    initialPending.kind == .pending, !initialPending.hasSucceeded
  else {
    Issue.record("The tracked status read did not begin at initial pending")
    return
  }
  #expect(await startIterator.next() == 0)

  // ASYNC-01: the first tracked read published exactly one pending turn —
  // there is no observable `initial` kind and no initialize-then-replace pair.
  #if DEBUG
  let pendingTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast pending"
  }
  #expect(pendingTurns.count == 1)
  #endif

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
}

@MainActor
@Test func `ASYNC-32 a skipping status watch is quiet at install and delivers old and new`()
  async
{
  // The lens carries the whole watch family, so `initial: .skip` follows
  // REACT-08's rule: installation demands the state (work starts) but calls
  // nothing; the first status turn delivers the pending it skipped as the old
  // half and the new status as the new half.
  let (cogs, m) = Cogs.forTestingWithController()
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let (deliveries, continuation) = AsyncStream.makeStream(
    of: (old: CogStatus<Int>, new: CogStatus<Int>).self
  )
  var deliveryCount = 0

  m.status.watch(forecast, initial: .skip, name: "watch.status.skip") {
    old, new in
    deliveryCount += 1
    continuation.yield((old: old, new: new))
  }
  var startIterator = work.starts.makeAsyncIterator()

  // Installation started the work but called nothing.
  #expect(await startIterator.next() == 0)
  #expect(deliveryCount == 0)

  work.succeed(0, with: 42)
  var deliveryIterator = deliveries.makeAsyncIterator()
  guard let first = await deliveryIterator.next() else {
    Issue.record("The skipping status watch stream ended before its first delivery")
    return
  }
  #expect(first.old.kind == .pending)
  #expect(first.old.value == 0)
  #expect(!first.old.hasSucceeded)
  #expect(first.new.kind == .success)
  #expect(first.new.value == 42)
}

@MainActor
@Test func `ASYNC-32 a status watch sees transitions an equal-success value watch gates away`()
  async
{
  let (cogs, m) = Cogs.forTestingWithController()
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let (statusEvents, statusContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  var valueEvents: [Int] = []

  m.status.watch(forecast, initial: .run, name: "watch.status") {
    _, new in
    statusContinuation.yield(new)
  }
  m.watch(forecast, initial: .run, name: "watch.value") { _, new in
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

}

@MainActor
@Test func `ASYNC-32 SwiftUI observes only the status fields its body reads`() async throws {
  let (cogs, m) = Cogs.forTestingWithController()
  let work = ControlledWork<Int>()
  let forecastCog = Cog<Int>.Async(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let kindNotices = OSAllocatedUnfairLock(initialState: 0)
  let valueNotices = OSAllocatedUnfairLock(initialState: 0)
  let successNotices = OSAllocatedUnfairLock(initialState: 0)
  let errorNotices = OSAllocatedUnfairLock(initialState: 0)
  let loadingNotices = OSAllocatedUnfairLock(initialState: 0)

  let initialKind = withObservationTracking {
    let forecast = cogs.status[forecastCog]
    return forecast.kind
  } onChange: {
    kindNotices.withLock { $0 += 1 }
  }
  let initialValue = withObservationTracking {
    let forecast = cogs.status[forecastCog]
    return forecast.value
  } onChange: {
    valueNotices.withLock { $0 += 1 }
  }
  let initiallySucceeded = withObservationTracking {
    let forecast = cogs.status[forecastCog]
    return forecast.hasSucceeded
  } onChange: {
    successNotices.withLock { $0 += 1 }
  }
  let initialError = withObservationTracking {
    let forecast = cogs.status[forecastCog]
    return forecast.error
  } onChange: {
    errorNotices.withLock { $0 += 1 }
  }
  let initiallyLoading = withObservationTracking {
    let forecast = cogs.status[forecastCog]
    return forecast.isLoading
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
