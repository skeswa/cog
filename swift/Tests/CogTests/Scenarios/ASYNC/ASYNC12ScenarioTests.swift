import Cog
import CogTesting
import Testing

@MainActor
private final class Async12ControlledWork<Key: Hashable & Sendable> {
  let starts: AsyncStream<Key>

  private let startContinuation: AsyncStream<Key>.Continuation
  private var continuations: [Key: CheckedContinuation<Int, Never>] = [:]

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Key.self)
  }

  func run(for key: Key) async -> Int {
    startContinuation.yield(key)
    return await withCheckedContinuation { continuations[key] = $0 }
  }

  func succeed(_ key: Key, with value: Int) {
    continuations.removeValue(forKey: key)?.resume(returning: value)
  }

  nonisolated deinit {}
}

@MainActor
@Test func `ASYNC-12 box keys fetch and publish status independently`() async {
  let cogs = Cogs.forTesting()
  let work = Async12ControlledWork<String>()
  let forecasts = AsyncCogBox<Int, String>(default: 0, name: "forecast") { _, zip in
    .run { await work.run(for: zip) }
  }
  let (homeStatuses, homeContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  let (awayStatuses, awayContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  let homeToken = cogs.run { c in homeContinuation.yield(c.status[forecasts["home"]]) }
  let awayToken = cogs.run { c in awayContinuation.yield(c.status[forecasts["away"]]) }
  var homeIterator = homeStatuses.makeAsyncIterator()
  var awayIterator = awayStatuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let homePending = await homeIterator.next(), let awayPending = await awayIterator.next()
  else {
    Issue.record("Both keyed status streams must begin with pending")
    return
  }
  if homePending.kind != .pending || homePending.hasSucceeded {
    Issue.record("The home key did not begin pending without a previous value")
  }
  if awayPending.kind != .pending || awayPending.hasSucceeded {
    Issue.record("The away key did not begin pending without a previous value")
  }

  let startedKeys = [await startIterator.next(), await startIterator.next()].compactMap { $0 }
  #expect(Set(startedKeys) == ["home", "away"])

  work.succeed("home", with: 72)
  guard let homeSuccess = await homeIterator.next() else {
    Issue.record("The home status stream ended before success")
    return
  }
  if homeSuccess.kind == .success {
    #expect(homeSuccess.value == 72)
  } else {
    Issue.record("The home key did not succeed independently")
  }
  let awayPendingAfterHome = cogs.status.peek(forecasts["away"])
  if awayPendingAfterHome.kind != .pending || awayPendingAfterHome.hasSucceeded {
    Issue.record("The away key did not remain pending while home succeeded")
  }

  work.succeed("away", with: 41)
  guard let awaySuccess = await awayIterator.next() else {
    Issue.record("The away status stream ended before success")
    return
  }
  if awaySuccess.kind == .success {
    #expect(awaySuccess.value == 41)
  } else {
    Issue.record("The away key did not complete independently")
  }

  withExtendedLifetime((homeToken, awayToken)) {}
}
