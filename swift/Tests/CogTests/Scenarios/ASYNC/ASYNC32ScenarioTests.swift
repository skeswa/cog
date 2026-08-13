import Cog
import CogTesting
import Testing

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
@Test func `ASYNC-32 the phase lens carries tracked reads with value parity`() async {
  let cogs = Cogtext.forTesting()
  let work = Async32ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let (phases, continuation) = AsyncStream.makeStream(of: CogPhase<Int>.self)

  // A tracked selector-side phase read demands the state exactly like a value
  // read would, and delivers every later phase turn to its consumer.
  let token = cogs.run { c in continuation.yield(c.phase[forecast]) }
  var phaseIterator = phases.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard case .some(.pending(previous: .none)) = await phaseIterator.next() else {
    Issue.record("The tracked phase read did not begin at initial pending")
    return
  }
  #expect(await startIterator.next() == 0)

  // The UI-boundary lens and the one-shot lens read the same settled phase,
  // and the plain value spellings beside them stay total.
  if case .pending(previous: .none) = cogs.phase[forecast] {
  } else {
    Issue.record("The UI phase lens did not read the settled pending phase")
  }
  if case .pending(previous: .none) = cogs.phase.peek(forecast) {
  } else {
    Issue.record("The one-shot phase lens did not read the settled pending phase")
  }
  #expect(cogs[forecast] == 0)
  #expect(cogs.peek(forecast) == 0)

  work.succeed(0, with: 42)
  guard case .some(.success(42)) = await phaseIterator.next() else {
    Issue.record("The tracked phase read did not observe success")
    return
  }
  withExtendedLifetime(token) {}
}

@MainActor
@Test func `ASYNC-32 a phase watch sees the turns an equal-success value watch gates away`()
  async
{
  let cogs = Cogtext.forTesting()
  let work = Async32ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let (phaseEvents, phaseContinuation) = AsyncStream.makeStream(of: CogPhase<Int>.self)
  var valueEvents: [Int] = []

  let phaseToken = cogs.phase.watch(forecast, initial: .run, name: "watch.phase") {
    _, new in
    phaseContinuation.yield(new)
  }
  let valueToken = cogs.watch(forecast, initial: .run, name: "watch.value") { _, new in
    valueEvents.append(new)
  }
  var phaseIterator = phaseEvents.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard case .some(.pending(previous: .none)) = await phaseIterator.next() else {
    Issue.record("The phase watch did not begin at initial pending")
    return
  }
  #expect(valueEvents == [0])
  #expect(await startIterator.next() == 0)

  work.succeed(0, with: 42)
  guard case .some(.success(42)) = await phaseIterator.next() else {
    Issue.record("The phase watch did not observe the first success")
    return
  }
  #expect(valueEvents == [0, 42])

  // An equal-success refresh cycles the full phase — pending, then success —
  // while the value watch beside the lens stays quiet.
  cogs.refresh(forecast)
  guard case .some(.pending(previous: .some(42))) = await phaseIterator.next() else {
    Issue.record("The phase watch did not observe reload pending")
    return
  }
  #expect(await startIterator.next() == 1)
  work.succeed(1, with: 42)
  guard case .some(.success(42)) = await phaseIterator.next() else {
    Issue.record("The phase watch did not observe the equal reload success")
    return
  }
  #expect(valueEvents == [0, 42])

  withExtendedLifetime((phaseToken, valueToken)) {}
}
