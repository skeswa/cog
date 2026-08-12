// The production install: how one app gets one context and guards that
// once-per-process construction path.
//
// This lives beside `Cogtext` rather than inside it because the registry is
// process-global state, not context state. A `Cogtext` knows nothing about
// being *the* context — it is the same object whether it was bootstrapped by
// an app or handed to a test — and keeping the registration out here is what
// lets an isolated testing context stay an ordinary context.

// MARK: - Installing the app's context

extension Cogtext {
  /// The app's context, once bootstrap has installed it.
  ///
  /// One `Optional` for the whole process, which is the honest shape of the
  /// thing: an app either has bootstrapped Cog or has not, and there is no
  /// third state. It is `static` and therefore lives in the extension rather
  /// than in the class — an extension cannot add storage to an instance, but
  /// process-wide storage is not instance storage.
  ///
  /// It is MainActor-isolated because `Cogtext` is, so
  /// reading and writing it needs no lock and no `nonisolated(unsafe)`. That
  /// isolation is also what makes the registration safe to install and remove
  /// inside a synchronous main-actor scope: nothing else can observe the slot
  /// halfway through.
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
  ///     WindowGroup { RootView().environment(\.cogs, cogs) }
  ///   }
  /// }
  /// ```
  ///
  /// The return value is the app's ownership handle. Keep it at the entry
  /// point and pass it to effects, services, and every scene; views receive it
  /// through the `\.cogs` environment value. Cog deliberately
  /// exposes no ambient static accessor: ops are instance methods on this
  /// context, and an isolated test substitutes its own context by passing a
  /// different instance through the same boundary.
  ///
  /// Calling it a second time is a programmer error and traps, in debug builds
  /// and in release builds alike. A test or preview runtime wants
  /// `Cogtext.forTesting()` instead.
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
  /// This is `package` because the only thing outside this file with a reason
  /// to inspect the registry is the `CogTesting` product's scoped-bootstrap
  /// fixture. Production code owns the context returned by
  /// ``Cogtext/bootstrapApp()`` and passes that object explicitly.
  package static var installedApp: Cogtext? {
    installedAppContext
  }

  /// Registers `cogs` as the app's context, trapping if one is already
  /// installed.
  ///
  /// Separate from ``Cogtext/bootstrapApp()`` so that every path that could
  /// ever make a context the app's context runs this one guard. Nothing else
  /// has to check, and no caller learns a new spelling.
  ///
  /// A second install is a programmer error, not a condition an app could
  /// handle: by the time it happens the process has two graphs, and every
  /// later read is a coin flip over which one holds the fact it wants. So the
  /// guard is unconditional — it fires in release exactly as it does in debug,
  /// because shipping the same mistake to users silently is strictly worse
  /// than stopping.
  ///
  /// It is spelled `fatalError` rather than `preconditionFailure` for the
  /// message, not the trap. Both trap in a release build, but the standard
  /// library drops `preconditionFailure`'s message under `-O` — the process
  /// dies with no explanation at all — while `fatalError` prints in every
  /// configuration. A guarantee to fail "with a clear error in debug builds
  /// and release builds" is only kept by the second.
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
  /// This exists for exactly one caller: the `CogTesting` product's scoped
  /// bootstrap, which installs an app context for the length of one
  /// synchronous test and takes it back out again. A suite runs thousands of
  /// tests in one process, so a test that proves something about the app
  /// install has to leave the process the way it found it.
  ///
  /// It is `package`, so it is not in the surface a shipping app links. An
  /// app cannot uninstall its context, which is the point: "one app, one
  /// graph" would not mean much if a feature could put the graph down and
  /// pick up a different one.
  package static func uninstallApp() {
    installedAppContext = nil
  }
}
