/// The immutable declaration behind an async derived value.
///
/// ``AsyncCog`` and ``AsyncCogBox`` are lightweight value references. They
/// retain one descriptor like this and, for a boxed declaration, pair it with
/// an erased key. A ``Cogtext`` uses the descriptor's object identity plus that
/// key to find or create an ``AsyncCogState``. Consequently, every context and
/// every key gets independent mutable phase, dependency, task, and generation
/// state while all of them share the declaration written by the caller.
///
/// The descriptor stores only declaration metadata and the synchronous half of
/// the async selector. It never stores a current phase or a running `Task`.
/// Those belong to ``AsyncCogState`` so one declaration can be used safely in
/// multiple isolated contexts and, for ``AsyncCogBox``, at multiple keys.
///
/// Async selection deliberately has two stages:
///
/// 1. `AsyncCogState` calls ``makeWork(_:key:)`` on the MainActor while Cog is
///    tracking reads through the supplied ``Reader``.
/// 2. The selector returns a ``Work`` whose operation runs after dependency
///    tracking has ended and may suspend.
///
/// This boundary makes dependency capture explicit. Only synchronous
/// `c[...]` reads used to choose the work can invalidate and restart the async
/// value; state touched later by the suspending operation cannot accidentally
/// become a graph dependency.
internal final class AsyncCogDescriptor<Value>: CogDescriptor {
  /// The declaration name used in turns, diagnostics, history, and task names.
  ///
  /// Every keyed state shares the label. Rendering adds the individual key,
  /// producing names such as `forecast[90210] pending`.
  let label: CogLabel

  /// Whether states of this declaration can be released when unobserved.
  ///
  /// Async derived state defaults to `whileObserved`: after grace expires the
  /// context cancels its task, advances its generation, and removes the state.
  /// Public `keepAlive` declaration sugar selects `app` instead.
  let lifetime: CogStateLifetime

  /// How a new selection interacts with work already in flight.
  ///
  /// The first slice exposes only `.latest`, so the current state machinery has
  /// no policy branch yet. Keeping the choice on the descriptor makes it part
  /// of the declaration, ready for later policies to remain consistent across
  /// all contexts and keys.
  let policy: LatestPolicy

  /// Selects one piece of async work while dependency tracking is active.
  ///
  /// The optional erased key lets keyless and boxed declarations share the
  /// runtime call path. ``AsyncCogBox`` installs the adapter that restores its
  /// concrete `Key` before user code runs. Explicit `@MainActor` keeps selector
  /// execution on the graph's actor under every client isolation default.
  private let selector: @MainActor (Reader<CogPhase<Value>>, AnyHashable?) -> Work<Value>

  /// Records the declaration choices shared by every state created from it.
  init(
    policy: LatestPolicy,
    selector: @escaping @MainActor (Reader<CogPhase<Value>>, AnyHashable?) -> Work<Value>,
    lifetime: CogStateLifetime = .whileObserved(grace: nil),
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.policy = policy
    self.selector = selector
  }

  /// Runs the synchronous selector for the state identified by `key`.
  ///
  /// The caller is responsible for opening the tracking scope. This method
  /// returns the description of work to start; it does not launch a task,
  /// publish pending, or mutate a phase. ``AsyncCogState`` performs those steps
  /// after the selector has returned and its dependency set is complete.
  func makeWork(_ reader: Reader<CogPhase<Value>>, key: AnyHashable?) -> Work<Value> {
    selector(reader, key)
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}
