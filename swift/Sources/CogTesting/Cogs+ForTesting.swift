public import Cog

// MARK: - Isolated runtimes

extension Cogs {
  /// A fresh, isolated context for one test or preview runtime.
  ///
  /// Each call creates separate Cog state. A write in one context does not
  /// change another context. Starting values and selector captures are still
  /// ordinary Swift values: if they contain a shared mutable object, that
  /// object remains shared outside Cog's storage.
  ///
  /// The factory mirrors production's single-call bootstrap exactly, with one
  /// addition: the `seeding` closure runs after the context exists and before
  /// any mechanism's `operate`, so a test arranges state first — quiet seeds
  /// and loud turns both — and then watches mechanisms come alive against
  /// it. An `initial: .run` watch therefore observes seeded values on its
  /// registration run. There is no late-start API, even for tests.
  ///
  /// Make one context per test or preview and pass it through that runtime.
  /// This factory does not install a production app context or require
  /// cleanup.
  ///
  /// ```swift
  /// @MainActor
  /// @Test func alertsWhenTheWeatherTurnsNice() {
  ///   let notifier = Notifier.recording()
  ///   let cogs = Cogs.forTesting(
  ///     seeding: { cogs in cogs.seedWeather(.cloudy(60), zip: zip) },
  ///     mechanisms: [WeatherMechanism(notifier: notifier)]
  ///   )
  ///   #expect(notifier.alerts.isEmpty)
  /// }
  /// ```
  ///
  /// This factory lives in `CogTesting`, so an app that imports only `Cog`
  /// cannot call it.
  ///
  /// - Parameters:
  ///   - clock: The monotonic clock context-owned timing work uses. Keep the
  ///     concrete clock in a timed test so the test can advance it without
  ///     waiting for wall-clock time.
  ///   - whileObservedGrace: The context default for declarations that do not
  ///     supply their own grace. Production and ordinary tests use 30 seconds;
  ///     a lifetime test passes an explicit duration to its controllable
  ///     clock.
  ///   - externalObservationTracking: The runtime path used for external
  ///     `@Observable` state. Ordinary tests select automatically. Compatibility
  ///     proofs can force the legacy one-shot path on a newer host without
  ///     changing production or another context.
  ///   - seeding: Arrangement run against the new context before any
  ///     mechanism operates. Defaults to none.
  ///   - mechanisms: Every mechanism this isolated runtime runs, operated
  ///     synchronously in array order exactly as production bootstrap would.
  ///     Defaults to none.
  /// - Returns: A new, uninstalled context whose mechanisms are live.
  public static func forTesting(
    clock: any Clock<Duration> = ContinuousClock(),
    whileObservedGrace: Duration = .seconds(30),
    externalObservationTracking: ExternalObservationTrackingForTesting = .automatic,
    seeding: ((Cogs) -> Void)? = nil,
    mechanisms: [any Mechanism] = []
  ) -> Cogs {
    let mode: CogExternalObservationTrackingMode =
      switch externalObservationTracking {
      case .automatic: .automatic
      case .legacy: .legacy
      }
    let cogs = Cogs(
      clock: clock,
      defaultWhileObservedGrace: whileObservedGrace,
      externalObservationTrackingMode: mode
    )
    seeding?(cogs)
    cogs.operateMechanisms(mechanisms)
    return cogs
  }
}
