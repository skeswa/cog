public import Cog

// MARK: - Bootstrap inspection

extension Cogs {
  /// Runs `body` with an app context bootstrapped, and takes it back out
  /// again.
  ///
  /// Use this only when a test covers app bootstrap. Other tests should use
  /// `Cogs.forTesting()`. The scoped context is removed even when `body`
  /// throws.
  ///
  /// ```swift
  /// @MainActor
  /// @Test func theWholeAppSharesOneGraph() {
  ///   Cogs.withBootstrappedApp { cogs in
  ///     #expect(Cogs.isBootstrappedApp(cogs))
  ///   }
  /// }
  /// ```
  ///
  /// The body is synchronous so no other MainActor work can observe the
  /// temporary install. Do not nest calls; the inner bootstrap is rejected as
  /// a second app install.
  ///
  /// - Parameters:
  ///   - mechanisms: The mechanism list handed to the real bootstrap, in the
  ///     order their registrations should hold. Defaults to none.
  ///   - body: What to run while the app context is installed. It receives
  ///     the context ``Cogs/bootstrapApp(mechanisms:)`` just made, its
  ///     mechanisms already live.
  /// - Returns: The value returned by `body`.
  /// - Throws: Any error thrown by `body`, after uninstalling the temporary
  ///   app context.
  @discardableResult
  public static func withBootstrappedApp<R>(
    mechanisms: [any Mechanism] = [],
    _ body: (Cogs) throws -> R
  ) rethrows -> R {
    defer { Cogs.uninstallApp() }
    return try body(Cogs.bootstrapApp(mechanisms: mechanisms))
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
  public static func isBootstrappedApp(_ context: Cogs) -> Bool {
    Cogs.installedApp === context
  }

  /// Whether an app context is installed right now.
  ///
  /// This exposes install state without exposing the installed context.
  public static var hasBootstrappedApp: Bool {
    Cogs.installedApp != nil
  }
}
