public import SwiftUI

/// Optional storage makes a missing composition boundary diagnosable.
///
/// A fabricated default context would split state from the graph bootstrapped
/// by the app. Keeping the default `nil` lets the public accessor fail with
/// installation guidance instead.
private struct CogsEnvironmentKey: EnvironmentKey {
  /// `nil` is a deliberate missing-installation sentinel, not a usable graph.
  nonisolated static var defaultValue: Cogs? { nil }
}

extension EnvironmentValues {
  /// Raw optional storage used only by the installation and checked-access APIs.
  ///
  /// Keeping this fileprivate prevents views from bypassing the fail-fast
  /// ``cogs`` accessor or installing `nil` accidentally.
  @MainActor
  fileprivate var installedCogs: Cogs? {
    get { self[CogsEnvironmentKey.self] }
    set { self[CogsEnvironmentKey.self] = newValue }
  }
}

extension EnvironmentValues {
  /// The app-wide Cog context installed above this view hierarchy.
  ///
  /// At app launch, keep the value returned by ``Cogs/bootstrapApp()`` and
  /// install it above every scene:
  ///
  /// ```swift
  /// WindowGroup {
  ///   RootView()
  ///     .cogEnvironment(cogs)
  /// }
  /// ```
  ///
  /// Tests and previews inject their isolated `Cogs.forTesting()` context
  /// through the same environment key.
  ///
  /// Every view that interacts with Cog should declare
  /// `@Environment(\.cogs) private var cogs` itself. Do not accept or forward
  /// the runtime through view initializers; intermediate views pass only
  /// domain values and identities.
  ///
  /// Reading this property does not itself read graph state or establish a Cog
  /// dependency. Subsequent `cogs[valueReference]` calls cross the tracked
  /// SwiftUI boundary. The property is MainActor-isolated because all context
  /// operations and values belong to the app's main-actor graph.
  ///
  /// - Returns: The exact context installed by the nearest ancestor.
  ///
  /// - Important: A missing installation traps in debug and release rather
  ///   than creating a second state island.
  @MainActor
  public var cogs: Cogs {
    guard let cogs = installedCogs else {
      fatalError(
        """
        No Cog context is installed in this view hierarchy. Keep the context \
        returned by `Cogs.bootstrapApp()` and inject it above every scene with \
        `.cogEnvironment(cogs)`. Tests and previews should inject their \
        isolated `Cogs.forTesting()` context through the same boundary.
        """
      )
    }
    return cogs
  }
}

extension View {
  /// Installs the app-wide Cog context above a SwiftUI view hierarchy.
  ///
  /// Call this at the composition root with the single context returned by
  /// ``Cogs/bootstrapApp()``. Descendants inherit that exact reference, so
  /// multiple scenes share one authoritative graph. Tests and previews may use
  /// their one isolated testing context instead.
  ///
  /// Install once at the hosted hierarchy's root. Each descendant that uses
  /// Cog resolves ``EnvironmentValues/cogs`` directly rather than receiving
  /// the runtime from its parent.
  ///
  /// This modifier installs the context only; it does not create state, read a
  /// value, or start observation.
  ///
  /// - Parameter cogs: The production or isolated-test graph for this runtime.
  /// - Returns: A view whose descendants resolve ``EnvironmentValues/cogs`` to
  ///   that exact context.
  @MainActor
  public func cogEnvironment(_ cogs: Cogs) -> some View {
    environment(\.installedCogs, cogs)
  }
}
