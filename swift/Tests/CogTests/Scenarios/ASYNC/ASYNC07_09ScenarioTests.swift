import Cog
import CogTesting
import Testing

private nonisolated struct Async07RunEvent: Sendable, Equatable {
  let name: String
  let request: Int
}

@MainActor
private final class Async07WorkProbe {
  let starts: AsyncStream<Async07RunEvent>
  let cancellations: AsyncStream<Async07RunEvent>

  private let startContinuation: AsyncStream<Async07RunEvent>.Continuation
  private let cancellationContinuation: AsyncStream<Async07RunEvent>.Continuation
  private var gateContinuations: [AsyncStream<Void>.Continuation] = []

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Async07RunEvent.self)
    (cancellations, cancellationContinuation) = AsyncStream.makeStream(
      of: Async07RunEvent.self
    )
  }

  func work(name: String, request: Int) -> Work<Int> {
    let event = Async07RunEvent(name: name, request: request)
    let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
    gateContinuations.append(gateContinuation)
    let startContinuation = startContinuation
    let cancellationContinuation = cancellationContinuation

    return .run {
      startContinuation.yield(event)
      var iterator = gate.makeAsyncIterator()
      guard await iterator.next() != nil else {
        cancellationContinuation.yield(event)
        throw CancellationError()
      }
      return request
    }
  }
}

@MainActor
@Test func `ASYNC-07 dependency changes replace explicit and default latest work`() async {
  let cogs = Cogtext.forTesting()
  let request = ManualCog<Int>(0)
  let probe = Async07WorkProbe()
  let defaultLatest = AsyncCog<Int>(default: 0, name: "default") { c in
    let value = c[request]
    return probe.work(name: "default", request: value)
  }
  let explicitLatest = AsyncCog<Int>(.latest, default: 0, name: "explicit") { c in
    let value = c[request]
    return probe.work(name: "explicit", request: value)
  }
  let token = cogs.run { c in
    _ = c[defaultLatest]
    _ = c[explicitLatest]
  }
  var startIterator = probe.starts.makeAsyncIterator()
  var cancellationIterator = probe.cancellations.makeAsyncIterator()

  let initialStarts = [await startIterator.next(), await startIterator.next()].compactMap { $0 }
  #expect(Set(initialStarts.map(\.name)) == ["default", "explicit"])
  #expect(initialStarts.allSatisfy { $0.request == 0 })

  cogs.commit("change request") { c in c[request] = 1 }

  let cancelled = [await cancellationIterator.next(), await cancellationIterator.next()]
    .compactMap { $0 }
  #expect(Set(cancelled.map(\.name)) == ["default", "explicit"])
  #expect(cancelled.allSatisfy { $0.request == 0 })

  let replacements = [await startIterator.next(), await startIterator.next()].compactMap { $0 }
  #expect(Set(replacements.map(\.name)) == ["default", "explicit"])
  #expect(replacements.allSatisfy { $0.request == 1 })
  withExtendedLifetime(token) {}
}

@MainActor
@Test func `ASYNC-09 replaced cancellation publishes no failure phase`() async {
  let cogs = Cogtext.forTesting()
  let request = ManualCog<Int>(0)
  let probe = Async07WorkProbe()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { c in
    let value = c[request]
    return probe.work(name: "forecast", request: value)
  }
  var phases: [CogPhase<Int>] = []
  let token = cogs.run { c in phases.append(c.phase[forecast]) }
  var startIterator = probe.starts.makeAsyncIterator()
  var cancellationIterator = probe.cancellations.makeAsyncIterator()

  #expect(await startIterator.next() == Async07RunEvent(name: "forecast", request: 0))
  cogs.commit("change request") { c in c[request] = 1 }
  #expect(await cancellationIterator.next() == Async07RunEvent(name: "forecast", request: 0))
  #expect(await startIterator.next() == Async07RunEvent(name: "forecast", request: 1))

  #expect(
    phases.allSatisfy { phase in
      if case .failure = phase { return false }
      return true
    }
  )
  withExtendedLifetime(token) {}
}
