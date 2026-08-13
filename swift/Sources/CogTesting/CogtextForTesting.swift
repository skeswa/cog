public import Cog

extension Cogtext {
  /// A fresh, isolated context for one test or preview runtime.
  ///
  /// Each call creates separate Cog state. A write in one context does not
  /// change another context. Starting values and selector captures are still
  /// ordinary Swift values: if they contain a shared mutable object, that
  /// object remains shared outside Cog's storage.
  ///
  /// Make one context per test or preview and pass it through that runtime.
  /// This factory does not install a production app context or require cleanup.
  ///
  /// ```swift
  /// @MainActor
  /// @Test func retryLimitDefaultsToThree() {
  ///   let cogs = Cogtext.forTesting()
  ///   #expect(cogs.peek(retryLimit) == 3)
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
  ///     a lifetime test passes an explicit duration to its controllable clock.
  /// - Returns: A new, uninstalled context with no materialized Cog state.
  public static func forTesting(
    clock: any Clock<Duration> = ContinuousClock(),
    whileObservedGrace: Duration = .seconds(30)
  ) -> Cogtext {
    Cogtext(clock: clock, defaultWhileObservedGrace: whileObservedGrace)
  }
}
