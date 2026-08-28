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
  /// any mechanism's `operate`. A test can arrange state with seeds or turns
  /// before mechanisms start. An `initial: .run` watch therefore observes seeded values on its
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
  /// This follows the same rules as ``forTesting`` but also returns a
  /// controller. Tests normally receive one only through a mechanism's
  /// `operate`. This factory adds a probe after the caller's mechanisms and
  /// returns the controller it captures:
  ///
  /// ```swift
  /// let (cogs, controller) = Cogs.forTestingWithController()
  /// controller.status.watch(forecastCog, initial: .run, name: "watch.forecast") { _, status in
  ///   statuses.append(status)
  /// }
  /// ```
  ///
  /// The probe's scope retains the controller for the context lifetime, as it
  /// would for an app-lifetime mechanism. It runs last, after caller mechanisms
  /// finish their assembly work. Its reserved name is `CogTesting.Probe`.
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
/// caller mechanism. Its `operate` runs last at assembly and only captures the
/// controller.
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
