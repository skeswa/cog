import Cog
import CogTesting
import Testing

private struct Async26Run: Hashable, Sendable {
  let key: String
  let generation: Int
}

@MainActor
private final class Async26ControlledWork {
  let starts: AsyncStream<Async26Run>

  private let startContinuation: AsyncStream<Async26Run>.Continuation
  private var nextGeneration: [String: Int] = [:]
  private var continuations: [Async26Run: CheckedContinuation<Int, Never>] = [:]

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Async26Run.self)
  }

  func makeWork(for key: String) -> Work<Int> {
    let run = Async26Run(key: key, generation: nextGeneration[key, default: 0])
    nextGeneration[key, default: 0] += 1
    let startContinuation = startContinuation

    return .run {
      startContinuation.yield(run)
      return await withCheckedContinuation { self.continuations[run] = $0 }
    }
  }

  func succeed(_ run: Async26Run, with value: Int) {
    guard let continuation = continuations.removeValue(forKey: run) else {
      fatalError("Async run \(run) completed before its work started.")
    }
    continuation.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-26 keyed value reads have stable per-key equality`() async throws {
  let (cogs, m) = probedContext()
  let work = Async26ControlledWork()
  let forecasts = CogBox<Int, String>.Async(default: 0, name: "forecast") { _, key in
    work.makeWork(for: key)
  }
  let (firstHomeValues, firstHomeContinuation) = AsyncStream.makeStream(of: Int.self)
  let (secondHomeValues, secondHomeContinuation) = AsyncStream.makeStream(of: Int.self)
  let (awayValues, awayContinuation) = AsyncStream.makeStream(of: Int.self)
  var firstHomeRuns = 0
  var secondHomeRuns = 0

  m.run { c in
    firstHomeRuns += 1
    firstHomeContinuation.yield(c[forecasts["home"]])
  }
  m.run { c in
    secondHomeRuns += 1
    secondHomeContinuation.yield(c[forecasts["home"]])
  }
  m.run { c in awayContinuation.yield(c[forecasts["away"]]) }
  var firstHomeIterator = firstHomeValues.makeAsyncIterator()
  var secondHomeIterator = secondHomeValues.makeAsyncIterator()
  var awayIterator = awayValues.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard case .some(let firstHomePending) = await firstHomeIterator.next(),
    case .some(let secondHomePending) = await secondHomeIterator.next(),
    case .some(let awayPending) = await awayIterator.next()
  else {
    Issue.record("Every keyed value stream must begin with the resting default value")
    return
  }
  #expect(firstHomePending == 0)
  #expect(secondHomePending == 0)
  #expect(awayPending == 0)

  let firstStarts = [await startIterator.next(), await startIterator.next()].compactMap { $0 }
  #expect(
    Set(firstStarts)
      == [
        Async26Run(key: "home", generation: 0),
        Async26Run(key: "away", generation: 0),
      ]
  )

  work.succeed(Async26Run(key: "home", generation: 0), with: 72)
  #expect(await firstHomeIterator.next() == 72)
  #expect(await secondHomeIterator.next() == 72)
  #expect(firstHomeRuns == 2)
  #expect(secondHomeRuns == 2)

  #if DEBUG
  let homeProjectionRuns = cogs.debugHistory.entries.filter {
    $0.event == .recompute && $0.name == "forecast.value[home]"
  }
  #expect(homeProjectionRuns.count == 2)
  #endif

  work.succeed(Async26Run(key: "away", generation: 0), with: 41)
  #expect(await awayIterator.next() == 41)
  #expect(firstHomeRuns == 2)
  #expect(secondHomeRuns == 2)

  cogs.refresh(forecasts["home"])
  #expect(await startIterator.next() == Async26Run(key: "home", generation: 1))
  #expect(firstHomeRuns == 2)
  #expect(secondHomeRuns == 2)

  let completionChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: completionChecked)
  work.succeed(Async26Run(key: "home", generation: 1), with: 72)
  try await completionChecked.wait()
  #expect(firstHomeRuns == 2)
  #expect(secondHomeRuns == 2)

}
