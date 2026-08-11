// The production install: how one app gets one context, and how the rest of
// the app finds it.
//
// This lives beside `Cogtext` rather than inside it because the registry is
// process-global state, not context state. A `Cogtext` knows nothing about
// being *the* context — it is the same object whether it was bootstrapped by
// an app or handed to a test — and keeping the registration out here is what
// lets an isolated testing context stay an ordinary context (§2.3).

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
  /// It is MainActor-isolated for free, because `Cogtext` is (§1.2), so
  /// reading and writing it needs no lock and no `nonisolated(unsafe)`. That
  /// isolation is also what makes the registration safe to install and remove
  /// inside a synchronous main-actor scope: nothing else can observe the slot
  /// halfway through.
  private static var installedAppContext: Cogtext?

  /// Creates the app's one context and installs it for the whole process.
  ///
  /// Call this once, at launch, from the app's entry point, and share the
  /// context it returns with every scene (§6.3):
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
  /// The returned context is also the one ``Cogtext/app`` hands back, so a
  /// feature that is nowhere near the app entry point — an op called off a
  /// notification, a service constructed before any view exists — resolves
  /// through the same graph without an injection chain reaching it first.
  /// Passing the context down is still the better habit where a call site can
  /// take it: injection is testable, and a test runtime substitutes its own
  /// context by handing over a different one rather than by reinstalling this
  /// one.
  ///
  /// It reads as a verb because installing the app's context is a
  /// once-per-process act, where `Cogtext.forTesting()` reads as a noun
  /// phrase because making a test context is ordinary value creation (§2.3).
  /// Neither is spelled `install`; that word belongs to effects (§6.3).
  ///
  /// - Returns: The app's context.
  @discardableResult
  public static func bootstrapApp() -> Cogtext {
    let cogs = Cogtext()
    installAsAppContext(cogs)
    return cogs
  }

  /// The app's context.
  ///
  /// This is the process's answer to "which graph?", and there is only ever
  /// one answer to give (§2.3). A feature file that reads through here and a
  /// view that reads through the injected `\.cogs` environment value are
  /// reading the same context, so a write either of them makes is a write the
  /// other sees.
  ///
  /// Reaching for this is not the first choice. Prefer taking a `Cogtext`
  /// as a parameter or reading the environment, both of which let a test hand
  /// the code under test an isolated context; this static is for the places
  /// that genuinely have nothing to take it from.
  ///
  /// - Precondition: ``Cogtext/bootstrapApp()`` has been called.
  public static var app: Cogtext {
    guard let installedAppContext else {
      preconditionFailure(
        """
        This app has no Cog context. Call Cogtext.bootstrapApp() once, at \
        launch, before any feature code reads through Cogtext.app. A test or \
        preview runtime should call Cogtext.forTesting() from the CogTesting \
        product instead and pass the context it gets back.
        """
      )
    }
    return installedAppContext
  }

  /// The app's context, or `nil` when nothing has bootstrapped one.
  ///
  /// The non-trapping view of the same slot, `package` because the only thing
  /// outside this file with a reason to ask is the `CogTesting` product's
  /// scoped-bootstrap seam. Application code gets ``Cogtext/app``, which does
  /// not offer "no context installed" as an outcome to handle, because in an
  /// app it is not one.
  package static var installedApp: Cogtext? {
    installedAppContext
  }

  /// Registers `cogs` as the app's context.
  ///
  /// Separate from ``Cogtext/bootstrapApp()`` so that every path that could
  /// ever make a context the app's context is this one line. `M1-29b` adds
  /// the second-install guard here, and adding it here is the whole change:
  /// nothing else has to move, and no caller learns a new spelling.
  private static func installAsAppContext(_ cogs: Cogtext) {
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
