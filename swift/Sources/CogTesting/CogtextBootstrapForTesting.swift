public import Cog

extension Cogtext {
  /// Runs `body` with an app context bootstrapped, and takes it back out
  /// again.
  ///
  /// Almost no test wants this. A test runtime is its own little app, so the
  /// normal spelling is `Cogtext.forTesting()`, which fabricates nothing
  /// process-wide and needs no cleanup. This is for the handful of tests whose
  /// subject *is* the app install — that bootstrap makes one context, that
  /// every feature resolves through it, that state outlives the views that
  /// showed it.
  ///
  /// The problem it solves is that the app context is process-global while a
  /// suite is one process running thousands of tests. A test that installed an
  /// app context and walked away would leave every later test running inside
  /// that install, and would make the very next `bootstrapApp()` anywhere in
  /// the suite fail as a second install. So the install here is scoped: it
  /// goes in before `body` and comes out after it, however `body` ends.
  ///
  /// ```swift
  /// @MainActor
  /// @Test func theWholeAppSharesOneGraph() {
  ///   Cogtext.withBootstrappedApp { cogs in
  ///     #expect(WeatherFeature.context() === cogs)
  ///   }
  /// }
  /// ```
  ///
  /// `body` is deliberately synchronous, and that is the containment
  /// argument, not a convenience. Everything Cog owns is MainActor-confined
  /// (§1.2), so a synchronous main-actor scope runs to completion before any
  /// other main-actor work — including any other test in a parallel run — gets
  /// a turn. The install therefore cannot be observed by, or collide with, a
  /// test that is not asking for it. An `await` inside the scope would open a
  /// window where it could, so there is no way to spell one.
  ///
  /// For the same reason this is not re-entrant, and must not be nested: the
  /// inner scope's exit would uninstall the outer scope's context. Nesting is
  /// a second install, and the production guard treats it as one.
  ///
  /// - Parameter body: What to run while the app context is installed. It
  ///   receives the context ``Cogtext/bootstrapApp()`` just made, which is
  ///   also what ``Cogtext/app`` returns for the length of the call.
  /// - Returns: Whatever `body` returns.
  @discardableResult
  public static func withBootstrappedApp<R>(_ body: (Cogtext) throws -> R) rethrows -> R {
    defer { Cogtext.uninstallApp() }
    return try body(Cogtext.bootstrapApp())
  }

  /// Whether an app context is installed right now.
  ///
  /// The narrow seam that lets a test check the process it is running in was
  /// left clean, without giving anything a way to reach into a context or to
  /// learn how contexts are stored. It answers one question — is there an app
  /// install in effect — which is the same question the production guard asks.
  public static var hasBootstrappedApp: Bool {
    Cogtext.installedApp != nil
  }
}
