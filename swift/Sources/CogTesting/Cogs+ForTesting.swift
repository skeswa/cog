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
  /// The factory mirrors production's single-call assembly exactly, with one
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
  ///     synchronously in array order exactly as production assembly would.
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

  /// A fresh, isolated context plus a live controller the test keeps.
  ///
  /// Everything ``forTesting(clock:whileObservedGrace:externalObservationTracking:seeding:mechanisms:)``
  /// says holds here too; the addition is the returned controller. Registration
  /// is a controller capability, and controllers reach tests only through a
  /// mechanism's `operate` — so a test that needs a reaction, watch, task, or
  /// gated scope mid-story would otherwise write its own capturing mechanism.
  /// This factory assembles that probe itself, after every caller mechanism,
  /// and returns its controller:
  ///
  /// ```swift
  /// let (cogs, controller) = Cogs.forTestingWithController()
  /// controller.status.watch(forecastCog, initial: .run, name: "watch.forecast") { _, status in
  ///   statuses.append(status)
  /// }
  /// ```
  ///
  /// Holding the controller mirrors an app-lifetime mechanism exactly: the
  /// runtime's scope retains every controller for the context's lifetime, so
  /// registrations made through it live as long as the context does. The probe
  /// operates last so its registrations always observe the caller mechanisms'
  /// assembly-time work, and its reserved assembly name is
  /// `CogTesting.Probe` — caller mechanisms keep their own names.
  ///
  /// - Parameters: The same parameters as
  ///   ``forTesting(clock:whileObservedGrace:externalObservationTracking:seeding:mechanisms:)``.
  /// - Returns: A new, uninstalled context whose mechanisms are live, and the
  ///   probe's controller.
  public static func forTestingWithController(
    clock: any Clock<Duration> = ContinuousClock(),
    whileObservedGrace: Duration = .seconds(30),
    externalObservationTracking: ExternalObservationTrackingForTesting = .automatic,
    seeding: ((Cogs) -> Void)? = nil,
    mechanisms: [any Mechanism] = []
  ) -> (cogs: Cogs, controller: MechanismController) {
    var controller: MechanismController!
    let cogs = forTesting(
      clock: clock,
      whileObservedGrace: whileObservedGrace,
      externalObservationTracking: externalObservationTracking,
      seeding: seeding,
      mechanisms: mechanisms + [ControllerProbeMechanism { controller = $0 }]
    )
    return (cogs, controller)
  }
}

/// The mechanism ``Cogs/forTestingWithController(clock:whileObservedGrace:externalObservationTracking:seeding:mechanisms:)``
/// assembles to capture a controller for the test.
///
/// An implementation detail rather than API: tests hold the controller, not
/// the probe. Its assembly name is namespaced so it cannot collide with a
/// caller mechanism, and `operate` runs once at assembly — after every caller
/// mechanism — doing nothing but the capture.
private struct ControllerProbeMechanism: Mechanism {
  /// The reserved assembly name, distinct from any reasonable caller name.
  let name = "CogTesting.Probe"

  /// Where the factory receives the captured controller.
  let capture: @MainActor (MechanismController) -> Void

  /// Creates the one probe an assembly carries.
  init(_ capture: @escaping @MainActor (MechanismController) -> Void) {
    self.capture = capture
  }

  /// Hands the controller to the factory; registers nothing itself.
  func operate(_ m: MechanismController) {
    capture(m)
  }
}
