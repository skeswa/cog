import Cog
import CogTesting
import Testing

@MainActor
private final class Async31ControlledWork {
  let starts: AsyncStream<Int>

  private let startContinuation: AsyncStream<Int>.Continuation
  private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]
  private var nextRun = 0

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func makeWork() -> Work<Int> {
    let run = nextRun
    nextRun += 1
    return .run {
      self.startContinuation.yield(run)
      return try await withCheckedThrowingContinuation { self.continuations[run] = $0 }
    }
  }

  /// The same controlled run, callable from a `Work` literal whose value type
  /// is optional — a `Work<Int>` cannot convert to `Work<Int?>`, but a
  /// closure returning `Int` can.
  func performRun() async throws -> Int {
    let run = nextRun
    nextRun += 1
    startContinuation.yield(run)
    return try await withCheckedThrowingContinuation { continuations[run] = $0 }
  }

  func succeed(_ run: Int, with value: Int) {
    continuations.removeValue(forKey: run)?.resume(returning: value)
  }

  func fail(_ run: Int, with error: any Error) {
    continuations.removeValue(forKey: run)?.resume(throwing: error)
  }
}

private nonisolated struct Async31Failure: Error {}

@MainActor
@Test func `ASYNC-31 an explicit default makes every value spelling total`() async throws {
  let cogs = Cogtext.forTesting()
  let work = Async31ControlledWork()
  let forecast = AsyncCog<Int>(default: -1, name: "forecast") { _ in
    work.makeWork()
  }
  let (values, continuation) = AsyncStream.makeStream(of: Int.self)
  let token = cogs.run { c in continuation.yield(c[forecast]) }
  var valueIterator = values.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  // Tracked selector read, UI-boundary read, and both peeks rest on the
  // declared default while the first generation is still in flight.
  #expect(await valueIterator.next() == -1)
  #expect(cogs[forecast] == -1)
  #expect(cogs.peek(forecast) == -1)
  #expect(await startIterator.next() == 0)

  work.succeed(0, with: 42)
  #expect(await valueIterator.next() == 42)
  #expect(cogs[forecast] == 42)
  #expect(cogs.peek(forecast) == 42)

  // Reload pending and a failed reload both keep the last accepted success
  // in every value spelling; the default appears only before the first one.
  cogs.refresh(forecast)
  #expect(await startIterator.next() == 1)
  #expect(cogs.peek(forecast) == 42)

  let failed = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: failed)
  work.fail(1, with: Async31Failure())
  try await failed.wait()
  #expect(cogs.peek(forecast) == 42)

  withExtendedLifetime(token) {}
}

@MainActor
@Test func `ASYNC-31 an Optional value may omit its default and rests at nil`() async {
  let cogs = Cogtext.forTesting()
  let work = Async31ControlledWork()
  let forecast = AsyncCog<Int?>(name: "forecast") { _ in
    .run { try await work.performRun() }
  }
  let (values, continuation) = AsyncStream.makeStream(of: Int?.self)
  let token = cogs.run { c in continuation.yield(c[forecast]) }
  var valueIterator = values.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard case .some(let resting) = await valueIterator.next() else {
    Issue.record("The value stream ended before the resting default")
    return
  }
  #expect(resting == nil)
  #expect(cogs.peek(forecast) == nil)
  #expect(await startIterator.next() == 0)

  work.succeed(0, with: 7)
  guard case .some(let loaded) = await valueIterator.next() else {
    Issue.record("The value stream ended before the first success")
    return
  }
  #expect(loaded == 7)
  #expect(cogs.peek(forecast) == 7)
  withExtendedLifetime(token) {}
}

@MainActor
@Test func `ASYNC-31 keyed declarations rest every key on the same default`() async {
  let cogs = Cogtext.forTesting()
  let work = Async31ControlledWork()
  let forecasts = AsyncCogBox<Int, String>(default: 0, name: "forecast") { _, _ in
    work.makeWork()
  }
  var startIterator = work.starts.makeAsyncIterator()

  #expect(cogs.peek(forecasts["home"]) == 0)
  #expect(cogs.peek(forecasts["away"]) == 0)
  #expect(await startIterator.next() == 0)
  #expect(await startIterator.next() == 1)

  let updated = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: updated)
  work.succeed(0, with: 72)
  try? await updated.wait()

  #expect(cogs.peek(forecasts["home"]) == 72)
  #expect(cogs.peek(forecasts["away"]) == 0)
}
