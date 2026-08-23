import Cog
import CogTesting
import Testing

// The starts-pending opening was the retired STREAM-02; nearly every STREAM
// test begins by asserting it, so it needs no ID of its own.

@MainActor
@Test func `STREAM-01 stream starts pending and publishes every element`() async throws {
  let (cogs, m) = probedContext()
  let (sequence, continuation) = AsyncStream.makeStream(of: Int.self)
  let readingsCog = Cog<Int>.Async(.latest, default: -1, name: "readings") { _ in
    .stream(sequence)
  }
  var statuses: [CogStatus<Int>] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.readings") { _, status in
    statuses.append(status)
  }

  let initial = cogs.status.peek(readingsCog)
  #expect(initial.kind == .pending)
  #expect(initial.value == -1)
  #expect(!initial.hasSucceeded)
  #expect(initial.isLoading)

  try await resolveAsyncStatus(in: cogs) { continuation.yield(10) }
  try await resolveAsyncStatus(in: cogs) { continuation.yield(20) }

  #expect(statuses.map(\.kind) == [.pending, .success, .success])
  #expect(statuses.map(\.value) == [-1, 10, 20])
  #expect(cogs.peek(readingsCog) == 20)

  continuation.finish()
}
