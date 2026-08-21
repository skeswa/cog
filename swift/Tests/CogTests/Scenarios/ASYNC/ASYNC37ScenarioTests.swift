import Cog
import CogTesting
import Testing

/// Keyed controlled work whose runs report cooperative cancellation per key.
@MainActor
private final class Async37ControlledWork {
  let starts: AsyncStream<String>
  let cancellations: AsyncStream<String>

  private let startContinuation: AsyncStream<String>.Continuation
  private let cancellationContinuation: AsyncStream<String>.Continuation
  private var continuations: [String: CheckedContinuation<Int, Never>] = [:]

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: String.self)
    (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: String.self)
  }

  func run(for key: String) async -> Int {
    let cancellationContinuation = cancellationContinuation
    return await withTaskCancellationHandler {
      startContinuation.yield(key)
      return await withCheckedContinuation { self.continuations[key] = $0 }
    } onCancel: {
      cancellationContinuation.yield(key)
    }
  }

  func finish(_ key: String, with value: Int) {
    continuations.removeValue(forKey: key)?.resume(returning: value)
  }

  nonisolated deinit {}
}

@MainActor
@Test func `ASYNC-37 releasing one key cancels only that key's work`() async throws {
  // Lifetime, work, and generations are all per exact keyed state: one key's
  // grace expiry cancels and releases that key alone, its late result turns
  // nothing, the sibling key's work completes untouched, and re-reading the
  // released key starts fresh.
  let clock = TestClock()
  let (cogs, m) = probedContext(clock: clock, whileObservedGrace: .seconds(10))
  let work = Async37ControlledWork()
  let forecasts = AsyncCogBox<Int, String>(default: 0, name: "forecast") { _, key in
    .run { await work.run(for: key) }
  }
  let awayWatcherAlive = ManualCog<Bool>(true)
  let (homeStatuses, homeContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in homeContinuation.yield(c.status[forecasts["home"]]) }
  m.whenever(awayWatcherAlive) { s in
    s.run { c in _ = c.status[forecasts["away"]] }
  }
  var homeIterator = homeStatuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  guard let homePending = await homeIterator.next(), homePending.kind == .pending else {
    Issue.record("Home did not begin at pending")
    return
  }
  #expect(await startIterator.next() == "home")
  #expect(await startIterator.next() == "away")

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(awayWatcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  // Only away's work was told to stop, and its late result turns nothing.
  #expect(await cancellationIterator.next() == "away")
  try await resolveAsyncStatus(in: cogs) {
    work.finish("away", with: 99)
  }
  #if DEBUG
  let awayResultTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast[away] success"
  }
  #expect(awayResultTurns.isEmpty)
  #endif

  // The watched sibling is untouched: still pending, and its result turns.
  try await resolveAsyncStatus(in: cogs) {
    work.finish("home", with: 70)
  }
  guard let homeSuccess = await homeIterator.next(), homeSuccess.kind == .success else {
    Issue.record("Home's result did not publish after away's release")
    return
  }
  #expect(homeSuccess.value == 70)

  // Reading the released key again starts fresh work with fresh status.
  let freshPending = cogs.status.peek(forecasts["away"])
  #expect(freshPending.kind == .pending)
  #expect(!freshPending.hasSucceeded)
  #expect(await startIterator.next() == "away")
}
