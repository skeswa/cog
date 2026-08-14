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

  /// Creates the app's one context, installs it for the whole process, and
  /// operates its mechanisms.
  ///
  /// Call this once, at launch, from the app's entry point, listing every
  /// mechanism the app runs, and share the context it returns with every
  /// scene:
  ///
  /// ```swift
  /// @main
  /// struct WeatherApp: App {
  ///   @State private var cogs: Cogs
  ///
  ///   init() {
  ///     let cogs = Cogs.bootstrapApp(mechanisms: [
  ///       WeatherMechanism(notifier: .live),
  ///     ])
  ///     _cogs = State(initialValue: cogs)
  ///   }
  ///
  ///   var body: some Scene {
  ///     WindowGroup { RootView().cogEnvironment(cogs) }
  ///   }
  /// }
  /// ```
  ///
  /// Each mechanism's `operate` runs synchronously in array order, and its
  /// writes settle, before this method returns: when bootstrap is done, every
  /// mechanism is live, and there is no later installation step. Two
  /// mechanisms sharing a name fail fast in every build.
  ///
  /// Keep the returned context at the app entry point. Use it there to
  /// install the SwiftUI environment above every scene. Every descendant view
  /// that interacts with Cog resolves `\.cogs` itself; never accept or
  /// forward the runtime through view initializers. There is no static
  /// accessor, so non-view composition and isolated test harnesses keep
  /// receiving their context explicitly.
  ///
  /// The context is MainActor-confined, uses a continuous production clock,
  /// and gives declarations without explicit lifetime grace a 30-second
  /// `whileObserved` default. Beyond operating the listed mechanisms,
  /// bootstrap creates no individual Cog state; the graph remains lazy until
  /// value references are used.
  ///
  /// A second call traps in every build. Tests and previews use
  /// `Cogs.forTesting(seeding:mechanisms:)`.
  ///
  /// - Parameter mechanisms: Every mechanism this app runs, in the order
  ///   their registrations should hold.
  /// - Returns: The newly installed, process-authoritative app context. Keep
  ///   this exact reference at the app root rather than bootstrapping again.
  @discardableResult
  public static func bootstrapApp(mechanisms: [any Mechanism] = []) -> Cogs {
    let cogs = Cogs(
      clock: ContinuousClock(),
      defaultWhileObservedGrace: .seconds(30)
    )
    installAsAppContext(cogs)
    cogs.operateMechanisms(mechanisms)
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
        Cog is already bootstrapped. `Cogs.bootstrapApp(mechanisms:)` \
        installs the app's one context and runs exactly once, at launch; a \
        second install would leave this process holding two graphs, with the \
        app's state split between them. Keep the context the first call \
        returned — its mechanisms are already live — and inject it above \
        every scene rather than bootstrapping again. Tests and previews are \
        separate app runtimes; give each its own isolated context by calling \
        `Cogs.forTesting(seeding:mechanisms:)` from the \
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
