#if DEBUG

import Cog
import CogTesting

extension Cogs {
  /// Installs a deterministic request service before a test first demands it.
  func seedWeatherService(_ service: WeatherService) {
    seed(weatherServiceSeedTarget, to: service)
  }

  /// Selects a current ZIP before a test installs effects or renders a picker.
  func seedCurrentZip(_ zip: ZipCode?) {
    seed(currentZipSeedTarget, to: zip)
  }
}

/// One request selected by the example's keyed async cog.
nonisolated struct WeatherRequestRun: Equatable, Sendable {
  /// Monotonic request identity, independent of the ZIP key.
  let id: Int
  /// The keyed state whose work selected this request.
  let zip: ZipCode
}

/// A deterministic weather service whose requests finish only when a test says so.
///
/// The controller intentionally ignores task cancellation. Tests can therefore
/// finish a replaced request and prove that `AsyncCogBox` rejects its stale
/// result instead of relying on cooperative cancellation for correctness.
actor WeatherRequestController {
  /// Buffered notification emitted only after a continuation has been stored.
  nonisolated let starts: AsyncStream<WeatherRequestRun>

  /// Send side for ``starts``; nonisolated because its type is sendable.
  private nonisolated let startContinuation: AsyncStream<WeatherRequestRun>.Continuation
  /// Next monotonically increasing run identity.
  private var nextID = 0
  /// Suspended request bodies keyed by run rather than ZIP to permit replacement.
  private var continuations: [Int: CheckedContinuation<WeatherReading, any Error>] = [:]

  /// Creates an empty controller with a buffered start stream.
  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: WeatherRequestRun.self)
  }

  /// A sendable service whose request bodies enter this actor.
  nonisolated var service: WeatherService {
    WeatherService { zip in
      try await self.request(for: zip)
    }
  }

  /// Stores one suspension before exposing the run to its test.
  private func request(for zip: ZipCode) async throws -> WeatherReading {
    let run = WeatherRequestRun(id: nextID, zip: zip)
    nextID += 1
    return try await withCheckedThrowingContinuation { continuation in
      continuations[run.id] = continuation
      startContinuation.yield(run)
    }
  }

  /// Resumes one selected run with a successful atomic reading.
  func succeed(_ run: WeatherRequestRun, with reading: WeatherReading) {
    continuations.removeValue(forKey: run.id)?.resume(returning: reading)
  }

  /// Resumes one selected run with the error Cog should publish as status.
  func fail(_ run: WeatherRequestRun, with error: any Error) {
    continuations.removeValue(forKey: run.id)?.resume(throwing: error)
  }
}

/// Resolves controlled work and waits until Cog has accepted or rejected it.
///
/// The acknowledgement closes the race between an operation returning and its
/// status publication. Callers can inspect public graph state immediately after
/// this function returns without yielding or polling.
@MainActor
func resolveWeatherRequest(
  in cogs: Cogs,
  _ resolution: () async -> Void
) async throws {
  let checked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: checked)
  await resolution()
  try await checked.wait()
}

/// Resolves controlled work and returns the exact public refresh outcome.
///
/// Unlike the internal acknowledgement helper above, this is the normal app
/// contract: the handle cannot complete for a replacement generation.
@MainActor
func resolveWeatherRefresh<Value>(
  _ refresh: CogRefresh<Value>,
  _ resolution: () async -> Void
) async -> CogRefresh<Value>.Outcome {
  await resolution()
  return await refresh.outcome
}

#endif
