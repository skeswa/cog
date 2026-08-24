import Cog
import CogTesting
import Testing

// An async declaration's `default:` is the value every read rests on before a
// first success, and async state defaults to `whileObserved` — so it is
// released and recreated as a matter of course rather than exceptionally. Both
// halves matter: the default has to be per state, and within one state it has
// to be one value rather than a fresh one at every publication.

private nonisolated enum Async40Error: Error {
  case offline
}

/// A mutable reference-type resting value, the case this scenario exists for.
@MainActor
private final class Placeholder {
  var note: String = ""

  nonisolated deinit {}
}

/// Counts how many resting values a declaration was asked to produce.
///
/// `default:` is an autoclosure, so the counting has to live in something the
/// expression calls rather than in a multi-statement closure body.
@MainActor
private final class PlaceholderProbe {
  /// How many times ``make()`` has produced a value.
  private(set) var runs = 0

  /// Produces one fresh resting value and records the call.
  func make() -> Placeholder {
    runs += 1
    return Placeholder()
  }

  nonisolated deinit {}
}

// MARK: - ASYNC-40

@MainActor
@Test func `ASYNC-40 two contexts rest on their own default object`() async throws {
  let probe = PlaceholderProbe()
  let work = AsyncStatusControlledWork<Placeholder>()
  let forecastCog = Cog<Placeholder>.Async(
    default: probe.make(),
    name: "forecast"
  ) { _ in work.makeWork() }

  let first = Cogs.forTesting()
  let second = Cogs.forTesting()

  let firstResting = first.peek(forecastCog)
  let secondResting = second.peek(forecastCog)
  firstResting.note = "written in the first context"

  #expect(firstResting !== secondResting)
  #expect(secondResting.note == "")
  #expect(probe.runs == 2)
}

@MainActor
@Test func `ASYNC-40 two keys of one box rest on their own default object`() async throws {
  let probe = PlaceholderProbe()
  let work = AsyncStatusControlledWork<Placeholder>()
  let forecastCogs = CogBox<Placeholder, String>.Async(
    default: probe.make(),
    name: "forecast"
  ) { _, _ in work.makeWork() }
  let cogs = Cogs.forTesting()

  let one = cogs.peek(forecastCogs["one"])
  let two = cogs.peek(forecastCogs["two"])
  one.note = "written under one"

  #expect(one !== two)
  #expect(two.note == "")
  #expect(probe.runs == 2)
}

@MainActor
@Test func `ASYNC-40 one state materializes its default once across pending and failure`()
  async throws
{
  // Pending, failure, and a retry's pending all carry the resting value while
  // nothing has succeeded. Producing it at each publication would hand out
  // three different objects for one state.
  let (cogs, m) = probedContext()
  let probe = PlaceholderProbe()
  let work = AsyncStatusControlledWork<Placeholder>()
  let forecastCog = Cog<Placeholder>.Async(
    default: probe.make(),
    name: "forecast"
  ) { _ in work.makeWork() }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Placeholder>.self)
  m.run { c in continuation.yield(c.status[forecastCog]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let pending = await statusIterator.next(), pending.kind == .pending else {
    Issue.record("The status stream did not begin at pending")
    return
  }
  #expect(await startIterator.next() == 0)
  let resting = pending.value

  try await resolveAsyncStatus(in: cogs) {
    work.fail(0, with: Async40Error.offline)
  }
  guard let failure = await statusIterator.next(), failure.kind == .failure else {
    Issue.record("The status stream did not observe the failure")
    return
  }
  #expect(failure.value === resting)

  cogs.refresh(forecastCog)
  guard let retryPending = await statusIterator.next(), retryPending.kind == .pending else {
    Issue.record("The retry did not publish pending")
    return
  }
  #expect(retryPending.value === resting)
  #expect(await startIterator.next() == 1)

  // One state, one default, however many turns it took to say so.
  #expect(probe.runs == 1)
  #expect(cogs.peek(forecastCog) === resting)
}

@MainActor
@Test func `ASYNC-40 a recreated state rests on a fresh default object`() async throws {
  let clock = TestClock()
  let (cogs, m) = probedContext(clock: clock, whileObservedGrace: .seconds(10))
  let probe = PlaceholderProbe()
  let work = AsyncStatusControlledWork<Placeholder>()
  let forecastCog = Cog<Placeholder>.Async(
    default: probe.make(),
    name: "forecast"
  ) { _ in work.makeWork() }
  let watcherAliveCog = Cog<Bool>.Manual { true }
  m.whenever(watcherAliveCog) { s in
    s.run { c in _ = c[forecastCog] }
  }
  var startIterator = work.starts.makeAsyncIterator()

  #expect(await startIterator.next() == 0)
  let beforeRelease = cogs.peek(forecastCog)
  beforeRelease.note = "mutated before release"
  #expect(probe.runs == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(watcherAliveCog, to: false)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  // The read that recreates the state produces a new default rather than
  // reviving the object the released state was resting on.
  let afterRelease = cogs.peek(forecastCog)
  #expect(probe.runs == 2)
  #expect(afterRelease !== beforeRelease)
  #expect(afterRelease.note == "")
}
