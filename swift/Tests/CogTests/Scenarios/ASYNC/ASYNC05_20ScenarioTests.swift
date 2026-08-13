import Cog
import CogTesting
import Testing

@MainActor
private final class Async05_20ControlledWork {
  private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]
  private let startContinuation: AsyncStream<Int>.Continuation
  let starts: AsyncStream<Int>

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func run(_ request: Int) async -> Int {
    startContinuation.yield(request)
    return await withCheckedContinuation { continuations[request] = $0 }
  }

  func succeed(_ request: Int, with value: Int) {
    guard let continuation = continuations.removeValue(forKey: request) else {
      fatalError("Async request \(request) completed before its work started.")
    }
    continuation.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-05 latest projection reads as a plain optional value`() async {
  let cogs = Cogtext.forTesting()
  let work = Async05_20ControlledWork()
  let forecast = AsyncCog<Int> { _ in
    .run { await work.run(0) }
  }
  let (values, continuation) = AsyncStream.makeStream(of: Int?.self)
  let token = cogs.run { c in continuation.yield(c[forecast.latest]) }
  var valueIterator = values.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard case .some(let pendingValue) = await valueIterator.next() else {
    Issue.record("The latest-value stream ended before pending")
    return
  }
  #expect(pendingValue == nil)

  #expect(await startIterator.next() == 0)
  work.succeed(0, with: 42)

  guard case .some(let completedValue) = await valueIterator.next() else {
    Issue.record("The latest-value stream ended before success")
    return
  }
  #expect(completedValue == 42)
  withExtendedLifetime(token) {}
}

@MainActor
@Test func `ASYNC-20 equal reload changes full phase but not latest consumers`() async {
  let cogs = Cogtext.forTesting()
  let request = ManualCog<Int>(0)
  let work = Async05_20ControlledWork()
  let forecast = AsyncCog<Int> { c in
    let currentRequest = c[request]
    return .run { await work.run(currentRequest) }
  }
  let latest = forecast.latest
  var latestConsumerRuns = 0
  let latestConsumer = Cog<Int?> { c in
    latestConsumerRuns += 1
    return c[latest]
  }
  let (phases, phaseContinuation) = AsyncStream.makeStream(of: CogPhase<Int>.self)
  let fullPhaseToken = cogs.run { c in phaseContinuation.yield(c[forecast]) }
  let latestConsumerToken = cogs.run { c in _ = c[latestConsumer] }
  var phaseIterator = phases.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard case .some(.pending(previous: .none)) = await phaseIterator.next() else {
    Issue.record("Expected initial pending without a previous value")
    return
  }
  #expect(latestConsumerRuns == 1)

  #expect(await startIterator.next() == 0)
  work.succeed(0, with: 42)
  guard case .some(.success(42)) = await phaseIterator.next() else {
    Issue.record("Expected the first success")
    return
  }
  #expect(latestConsumerRuns == 2)

  cogs.commit { c in c[request] = 1 }
  guard case .some(.pending(previous: .some(42))) = await phaseIterator.next() else {
    Issue.record("Expected reload pending with the last successful value")
    return
  }
  #expect(latestConsumerRuns == 2)

  #expect(await startIterator.next() == 1)
  work.succeed(1, with: 42)
  guard case .some(.success(42)) = await phaseIterator.next() else {
    Issue.record("Expected the equal reload success")
    return
  }
  #expect(latestConsumerRuns == 2)

  withExtendedLifetime((fullPhaseToken, latestConsumerToken)) {}
}
