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
@Test func `ASYNC-05 value read reads as a plain value like a manual cog`() async {
  let cogs = Cogs.forTesting()
  let work = Async05_20ControlledWork()
  let forecast = AsyncCog<Int?>(default: nil) { _ in
    .run { await work.run(0) }
  }
  let (values, continuation) = AsyncStream.makeStream(of: Int?.self)
  let token = cogs.run { c in continuation.yield(c[forecast]) }
  var valueIterator = values.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard case .some(let pendingValue) = await valueIterator.next() else {
    Issue.record("The value stream ended before the resting default")
    return
  }
  #expect(pendingValue == nil)

  #expect(await startIterator.next() == 0)
  work.succeed(0, with: 42)

  guard case .some(let completedValue) = await valueIterator.next() else {
    Issue.record("The value stream ended before success")
    return
  }
  #expect(completedValue == 42)
  withExtendedLifetime(token) {}
}

@MainActor
@Test func `ASYNC-20 equal reload changes metadata but not value consumers`() async {
  let cogs = Cogs.forTesting()
  let request = ManualCog<Int>(0)
  let work = Async05_20ControlledWork()
  let forecast = AsyncCog<Int>(default: 0) { c in
    let currentRequest = c[request]
    return .run { await work.run(currentRequest) }
  }
  var valueConsumerRuns = 0
  let valueConsumer = Cog<Int> { c in
    valueConsumerRuns += 1
    return c[forecast]
  }
  let (phases, phaseContinuation) = AsyncStream.makeStream(of: CogMeta<Int>.self)
  let fullPhaseToken = cogs.run { c in phaseContinuation.yield(c.meta[forecast]) }
  let valueConsumerToken = cogs.run { c in _ = c[valueConsumer] }
  var phaseIterator = phases.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard case .some(.pending(_, hasSucceeded: false)) = await phaseIterator.next() else {
    Issue.record("Expected initial pending without a previous value")
    return
  }
  #expect(valueConsumerRuns == 1)

  #expect(await startIterator.next() == 0)
  work.succeed(0, with: 42)
  guard case .some(.success(42)) = await phaseIterator.next() else {
    Issue.record("Expected the first success")
    return
  }
  #expect(valueConsumerRuns == 2)

  cogs.commit { c in c[request] = 1 }
  guard case .some(.pending(value: 42, hasSucceeded: true)) = await phaseIterator.next() else {
    Issue.record("Expected reload pending with the last successful value")
    return
  }
  #expect(valueConsumerRuns == 2)

  #expect(await startIterator.next() == 1)
  work.succeed(1, with: 42)
  guard case .some(.success(42)) = await phaseIterator.next() else {
    Issue.record("Expected the equal reload success")
    return
  }
  #expect(valueConsumerRuns == 2)

  withExtendedLifetime((fullPhaseToken, valueConsumerToken)) {}
}
