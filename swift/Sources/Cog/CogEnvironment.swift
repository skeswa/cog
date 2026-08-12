public import SwiftUI

/// The explicit SwiftUI composition boundary for an app's Cog context.
private struct CogtextEnvironmentKey: EnvironmentKey {
  nonisolated static var defaultValue: Cogtext {
    fatalError(
      """
      No Cog context is installed in this view hierarchy. Keep the context \
      returned by `Cogtext.bootstrapApp()` and inject it above every scene with \
      `.environment(\\.cogs, cogs)`. Tests and previews should inject their \
      isolated `Cogtext.forTesting()` context through the same boundary.
      """
    )
  }
}

extension EnvironmentValues {
  /// The app-wide Cog context installed above this view hierarchy.
  ///
  /// At app launch, keep the value returned by ``Cogtext/bootstrapApp()`` and
  /// install it above every scene:
  ///
  /// ```swift
  /// WindowGroup {
  ///   RootView()
  ///     .environment(\.cogs, cogs)
  /// }
  /// ```
  ///
  /// Tests and previews inject their isolated `Cogtext.forTesting()` context
  /// through the same environment key.
  @MainActor
  public var cogs: Cogtext {
    get { self[CogtextEnvironmentKey.self] }
    set { self[CogtextEnvironmentKey.self] = newValue }
  }
}
