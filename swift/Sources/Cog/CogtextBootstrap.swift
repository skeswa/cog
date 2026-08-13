// The process-wide production install guard. It enforces singular app state but
// intentionally exposes no service-locator accessor; tests and previews do not
// enter this registry.

// MARK: - Installing the app's context

extension Cogs {
  /// The app's context, once bootstrap has installed it.
  ///
  /// MainActor isolation makes access serialized without a lock. The strong
  /// reference keeps the authoritative production graph alive for the process
  /// after bootstrap, independently of scene recreation.
  private static var installedAppContext: Cogs?

  /// Creates the app's one context and installs it for the whole process.
  ///
  /// Call this once, at launch, from the app's entry point, and share the
  /// context it returns with every scene:
  ///
  /// ```swift
  /// @main
  /// struct WeatherApp: App {
  ///   @State private var cogs: Cogs
  ///
  ///   init() {
  ///     let cogs = Cogs.bootstrapApp()
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
  /// The context is MainActor-confined, uses a continuous production clock,
  /// and gives declarations without explicit lifetime grace a 30-second
  /// `whileObserved` default. Bootstrap creates no individual Cog state; the
  /// graph remains lazy until value references are used.
  ///
  /// A second call traps in every build. Tests and previews use
  /// `Cogs.forTesting()`.
  ///
  /// - Returns: The newly installed, process-authoritative app context. Keep and
  ///   pass this exact reference rather than bootstrapping again.
  @discardableResult
  public static func bootstrapApp() -> Cogs {
    let cogs = Cogs(
      clock: ContinuousClock(),
      defaultWhileObservedGrace: .seconds(30)
    )
    installAsAppContext(cogs)
    return cogs
  }

  /// The app's context, or `nil` when nothing has bootstrapped one.
  ///
  /// Package access is only for the `CogTesting` bootstrap fixture to verify
  /// installation identity without making production code depend on global
  /// lookup.
  package static var installedApp: Cogs? {
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
  private static func installAsAppContext(_ cogs: Cogs) {
    guard installedAppContext == nil else {
      fatalError(
        """
        Cog is already bootstrapped. `Cogs.bootstrapApp()` installs the \
        app's one context and runs exactly once, at launch; a second install \
        would leave this process holding two graphs, with the app's state \
        split between them. Keep the context the first call returned and pass \
        it to your scenes, effects, and services rather than bootstrapping \
        again. A test or a preview is a separate app runtime and wants its \
        own isolated context: call `Cogs.forTesting()` from the \
        `CogTesting` product, or, when the app install itself is the subject, \
        `Cogs.withBootstrappedApp { }` — which is not re-entrant, so do \
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
  /// This drops the registry's strong reference; normal context deinitialization
  /// then cancels graph-owned work and breaks dependency chains when no other
  /// references remain. Shipping apps cannot call it.
  package static func uninstallApp() {
    installedAppContext = nil
  }
}
