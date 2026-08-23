public import Cog

// MARK: - Assembly inspection

extension Cogs {
  /// Runs `body` with an app context assembled, and takes it back out
  /// again.
  ///
  /// Use this only when a test covers app assembly. Other tests should use
  /// `Cogs.forTesting()`. The scoped context is removed even when `body`
  /// throws.
  ///
  /// ```swift
  /// @MainActor
  /// @Test func theWholeAppSharesOneGraph() {
  ///   Cogs.withAssembledCogs { cogs in
  ///     #expect(Cogs.isAssembledCogs(cogs))
  ///   }
  /// }
  /// ```
  ///
  /// The body is synchronous so no other MainActor work can observe the
  /// temporary install. Do not nest calls; the inner assembly is rejected as
  /// a second app install.
  ///
  /// - Parameters:
  ///   - mechanisms: The mechanism list handed to the real assembly, in the
  ///     order their registrations should hold. Defaults to none.
  ///   - body: What to run while the app context is installed. It receives
  ///     the context ``Cogs/assemble(mechanisms:)`` just made, its
  ///     mechanisms already live.
  /// - Returns: The value returned by `body`.
  /// - Throws: Any error thrown by `body`, after uninstalling the temporary
  ///   app context.
  @discardableResult
  public static func withAssembledCogs<R>(
    mechanisms: [any Mechanism] = [],
    _ body: (Cogs) throws -> R
  ) rethrows -> R {
    defer { Cogs.uninstallCogs() }
    return try body(Cogs.assemble(mechanisms: mechanisms))
  }

  /// Whether `context` is the exact object in the production-install slot.
  ///
  /// This proves assembly identity without adding an ambient context accessor
  /// to the shipping `Cog` product. It is a lifecycle diagnostic only: tests
  /// still receive the context from ``withAssembledCogs(_:)`` and pass it
  /// through the same composition boundaries as production.
  ///
  /// - Parameter context: The context whose identity should be compared with
  ///   the process's app-install slot.
  /// - Returns: `true` only when `context` is the currently installed object.
  public static func isAssembledCogs(_ context: Cogs) -> Bool {
    Cogs.installedCogs === context
  }

  /// Whether an app context is installed right now.
  ///
  /// This exposes install state without exposing the installed context.
  public static var hasAssembledCogs: Bool {
    Cogs.installedCogs != nil
  }
}
