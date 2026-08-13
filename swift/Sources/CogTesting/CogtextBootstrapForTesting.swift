public import Cog

extension Cogtext {
  /// Runs `body` with an app context bootstrapped, and takes it back out
  /// again.
  ///
  /// Use this only when a test covers app bootstrap. Other tests should use
  /// `Cogtext.forTesting()`. The scoped context is removed even when `body`
  /// throws.
  ///
  /// ```swift
  /// @MainActor
  /// @Test func theWholeAppSharesOneGraph() {
  ///   Cogtext.withBootstrappedApp { cogs in
  ///     #expect(Cogtext.isBootstrappedApp(cogs))
  ///   }
  /// }
  /// ```
  ///
  /// The body is synchronous so no other MainActor work can observe the
  /// temporary install. Do not nest calls; the inner bootstrap is rejected as
  /// a second app install.
  ///
  /// - Parameter body: What to run while the app context is installed. It
  ///   receives the context ``Cogtext/bootstrapApp()`` just made.
  /// - Returns: The value returned by `body`.
  /// - Throws: Any error thrown by `body`, after uninstalling the temporary
  ///   app context.
  @discardableResult
  public static func withBootstrappedApp<R>(_ body: (Cogtext) throws -> R) rethrows -> R {
    defer { Cogtext.uninstallApp() }
    return try body(Cogtext.bootstrapApp())
  }

  /// Whether `context` is the exact object in the production-install slot.
  ///
  /// This proves bootstrap identity without adding an ambient context accessor
  /// to the shipping `Cog` product. It is a lifecycle diagnostic only: tests
  /// still receive the context from ``withBootstrappedApp(_:)`` and pass it
  /// through the same composition boundaries as production.
  ///
  /// - Parameter context: The context whose identity should be compared with
  ///   the process's app-install slot.
  /// - Returns: `true` only when `context` is the currently installed object.
  public static func isBootstrappedApp(_ context: Cogtext) -> Bool {
    Cogtext.installedApp === context
  }

  /// Whether an app context is installed right now.
  ///
  /// This exposes install state without exposing the installed context.
  public static var hasBootstrappedApp: Bool {
    Cogtext.installedApp != nil
  }
}
