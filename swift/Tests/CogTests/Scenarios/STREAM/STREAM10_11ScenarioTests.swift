import Cog
import CogTesting
import Testing

@MainActor
@Test func `STREAM-10 equal elements are quiet across every public consumer`() async throws {
  let (cogs, m) = probedContext()
  let (sequence, continuation) = AsyncStream.makeStream(of: Int.self)
  let readingsCog = AsyncCog<Int>(.latest, default: -1, name: "readings") { _ in
    .stream(sequence)
  }
  var statuses: [CogStatus<Int>] = []
  var watchedValues: [Int] = []
  var reactionValues: [Int] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.readings.status") { _, status in
    statuses.append(status)
  }
  m.watch(readingsCog, initial: .run, name: "watch.readings.value") { _, value in
    watchedValues.append(value)
  }
  m.run { c in
    let readings = c[readingsCog]
    reactionValues.append(readings)
  }

  try await resolveAsyncStatus(in: cogs) { continuation.yield(7) }
  #if DEBUG
  let historyCountBeforeDuplicate = cogs.debugHistory.count
  #endif
  try await resolveAsyncStatus(in: cogs) { continuation.yield(7) }

  #expect(statuses.map(\.kind) == [.pending, .success])
  #expect(statuses.map(\.value) == [-1, 7])
  #expect(watchedValues == [-1, 7])
  #expect(reactionValues == [-1, 7])
  #if DEBUG
  #expect(cogs.debugHistory.count == historyCountBeforeDuplicate)
  #endif

  try await resolveAsyncStatus(in: cogs) { continuation.yield(8) }
  #expect(statuses.map(\.value) == [-1, 7, 8])
  #expect(watchedValues == [-1, 7, 8])
  #expect(reactionValues == [-1, 7, 8])
  #if DEBUG
  let successTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "readings success"
  }
  #expect(successTurns.count == 2)
  #endif

  try await resolveAsyncStatus(in: cogs) { continuation.finish() }
}

/// An equal-looking stream value with deliberately no equality contract.
private nonisolated struct OpaqueReading {
  /// The domain payload used only to show that two instances look alike.
  let value: Int
}

@MainActor
@Test func `STREAM-11 values without equality publish conservatively`() async throws {
  let (cogs, m) = probedContext()
  let (sequence, continuation) = AsyncStream.makeStream(of: OpaqueReading.self)
  let readingsCog = AsyncCog<OpaqueReading>(
    .latest,
    default: OpaqueReading(value: -1),
    name: "opaqueReadings"
  ) { _ in
    .stream(sequence)
  }
  var statusValues: [Int] = []
  var watchedValues: [Int] = []
  var reactionValues: [Int] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.opaque.status") { _, status in
    statusValues.append(status.value.value)
  }
  m.watch(readingsCog, initial: .run, name: "watch.opaque.value") { _, reading in
    watchedValues.append(reading.value)
  }
  m.run { c in
    let readings = c[readingsCog]
    reactionValues.append(readings.value)
  }

  try await resolveAsyncStatus(in: cogs) { continuation.yield(OpaqueReading(value: 4)) }
  try await resolveAsyncStatus(in: cogs) { continuation.yield(OpaqueReading(value: 4)) }

  #expect(statusValues == [-1, 4, 4])
  #expect(watchedValues == [-1, 4, 4])
  #expect(reactionValues == [-1, 4, 4])
  #if DEBUG
  let successTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "opaqueReadings success"
  }
  #expect(successTurns.count == 2)
  #endif

  try await resolveAsyncStatus(in: cogs) { continuation.finish() }
}
