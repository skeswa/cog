public import Cog

extension Cogtext {
  /// A fresh, isolated context for one test or preview runtime.
  ///
  /// A test is its own little app: it starts with nothing in the graph, does
  /// its work, and ends. So this hands back a context with no nodes in it,
  /// where every declaration in the process starts again at its starting value.
  /// Nothing has to be installed, reset, or torn down first, and nothing a
  /// previous test did can reach this one — the state a test can see is exactly
  /// the state it put there.
  ///
  /// Ask as often as you like. Two previews on screen at once, or a suite
  /// running tests in parallel, each get their own context and cannot see one
  /// another's values.
  ///
  /// A context from here is never the app's context. It does not register as
  /// the production context, so it does not trip the guard on a second
  /// production install, and a test that makes twenty of these has still made
  /// zero app contexts.
  ///
  /// The one rule is the same rule production follows: a test runtime is
  /// singular too. Make one context per test and pass it around; making a
  /// second one partway through a test fragments the state under test into two
  /// worlds, which is the bug this whole design exists to prevent.
  ///
  /// ```swift
  /// @MainActor
  /// @Test func retryLimitDefaultsToThree() {
  ///   let cogs = Cogtext.forTesting()
  ///   #expect(cogs.read(retryLimit) == 3)
  /// }
  /// ```
  ///
  /// This lives in `CogTesting` rather than `Cog` on purpose. An app target
  /// that depends only on `Cog` has no way to name this function, so a test
  /// helper cannot drift into shipping code by accident.
  ///
  /// - Parameter clock: The monotonic clock context-owned timing work uses.
  ///   Keep the concrete clock in a timed test so the test can advance it
  ///   without waiting for wall-clock time.
  public static func forTesting(
    clock: any Clock<Duration> = ContinuousClock()
  ) -> Cogtext {
    Cogtext(clock: clock)
  }
}
