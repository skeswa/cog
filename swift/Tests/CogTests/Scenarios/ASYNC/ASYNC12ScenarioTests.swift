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
@Test func `ASYNC-12 box keys fetch and phase independently`() async {
  let cogs = Cogtext.forTesting()
  let work = Async12ControlledWork<String>()
  let forecasts = AsyncCogBox<Int, String>(default: 0, name: "forecast") { _, zip in
    .run { await work.run(for: zip) }
  }
  let (homePhases, homeContinuation) = AsyncStream.makeStream(of: CogPhase<Int>.self)
  let (awayPhases, awayContinuation) = AsyncStream.makeStream(of: CogPhase<Int>.self)
  let homeToken = cogs.run { c in homeContinuation.yield(c.phase[forecasts["home"]]) }
  let awayToken = cogs.run { c in awayContinuation.yield(c.phase[forecasts["away"]]) }
  var homeIterator = homePhases.makeAsyncIterator()
  var awayIterator = awayPhases.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let homePending = await homeIterator.next(), let awayPending = await awayIterator.next()
  else {
    Issue.record("Both keyed phase streams must begin with pending")
    return
  }
  if case .pending(previous: .none) = homePending {
  } else {
    Issue.record("The home key did not begin pending without a previous value")
  }
  if case .pending(previous: .none) = awayPending {
  } else {
    Issue.record("The away key did not begin pending without a previous value")
  }

  let startedKeys = [await startIterator.next(), await startIterator.next()].compactMap { $0 }
  #expect(Set(startedKeys) == ["home", "away"])

  work.succeed("home", with: 72)
  guard let homeSuccess = await homeIterator.next() else {
    Issue.record("The home phase stream ended before success")
    return
  }
  if case .success(let value) = homeSuccess {
    #expect(value == 72)
  } else {
    Issue.record("The home key did not succeed independently")
  }
  if case .pending(previous: .none) = cogs.phase.peek(forecasts["away"]) {
  } else {
    Issue.record("The away key did not remain pending while home succeeded")
  }

  work.succeed("away", with: 41)
  guard let awaySuccess = await awayIterator.next() else {
    Issue.record("The away phase stream ended before success")
    return
  }
  if case .success(let value) = awaySuccess {
    #expect(value == 41)
  } else {
    Issue.record("The away key did not complete independently")
  }

  withExtendedLifetime((homeToken, awayToken)) {}
}
