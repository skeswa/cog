// The process-wide production context registry. Test contexts do not use it.

// MARK: - Installing the app's context

extension Cogtext {
  /// The app's context, once bootstrap has installed it.
  ///
  /// MainActor isolation makes access serialized without a lock.
  private static var installedAppContext: Cogtext?

  /// Creates the app's one context and installs it for the whole process.
  ///
  /// Call this once, at launch, from the app's entry point, and share the
  /// context it returns with every scene:
  ///
  /// ```swift
  /// @main
  /// struct WeatherApp: App {
  ///   @State private var cogs: Cogtext
  ///
  ///   init() {
  ///     let cogs = Cogtext.bootstrapApp()
  ///     _cogs = State(initialValue: cogs)
  ///   }
  ///
  ///   var body: some Scene {
  ///     WindowGroup { RootView().cogEnvironment(cogs) }
  ///   }
  /// }
  /// ```
  ///
  /// Keep the returned context at the app entry point. Pass it to effects and
  /// services; views receive it through `\.cogs`. There is no static accessor,
  /// so tests can pass an isolated context through the same boundaries.
  ///
  /// A second call traps in every build. Tests and previews use
  /// `Cogtext.forTesting()`.
  ///
  /// - Returns: The app's context.
  @discardableResult
  public static func bootstrapApp() -> Cogtext {
    let cogs = Cogtext(
      clock: ContinuousClock(),
      defaultWhileObservedGrace: .seconds(30)
    )
    installAsAppContext(cogs)
    return cogs
  }

  /// The app's context, or `nil` when nothing has bootstrapped one.
  ///
  /// Package access is for the `CogTesting` bootstrap fixture.
  package static var installedApp: Cogtext? {
    installedAppContext
  }

  /// Registers `cogs` as the app's context, trapping if one is already
  /// installed.
  ///
  /// Every production install goes through this guard. A second graph would
  /// split the app's state, so the guard runs in debug and release builds.
  ///
  /// `fatalError` preserves its message under `-O`;
  /// `preconditionFailure` does not.
  private static func installAsAppContext(_ cogs: Cogtext) {
    guard installedAppContext == nil else {
      fatalError(
        """
        Cog is already bootstrapped. `Cogtext.bootstrapApp()` installs the \
        app's one context and runs exactly once, at launch; a second install \
        would leave this process holding two graphs, with the app's state \
        split between them. Keep the context the first call returned and pass \
        it to your scenes, effects, and services rather than bootstrapping \
        again. A test or a preview is a separate app runtime and wants its \
        own isolated context: call `Cogtext.forTesting()` from the \
        `CogTesting` product, or, when the app install itself is the subject, \
        `Cogtext.withBootstrappedApp { }` — which is not re-entrant, so do \
        not nest it.
        """
      )
    }
    installedAppContext = cogs
  }

  /// Forgets the app's context, leaving the process as it was before
  /// bootstrap.
  ///
  /// Used by `CogTesting` to restore the process after a scoped bootstrap test.
  /// Shipping apps cannot call it.
  package static func uninstallApp() {
    installedAppContext = nil
  }
}
