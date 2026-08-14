/// The immutable declaration behind an async derived value.
///
/// ``AsyncCog`` and ``AsyncCogBox`` are lightweight value references. They
/// retain one descriptor like this and, for a boxed declaration, pair it with
/// an erased key. A ``Cogs`` uses the descriptor's object identity plus that
/// key to find or create an ``AsyncCogState``. Consequently, every context and
/// every key gets independent mutable status, dependency, task, and generation
/// state while all of them share the declaration written by the caller.
///
/// The descriptor stores only declaration metadata and the synchronous half of
/// the async selector. It never stores current status or a running `Task`.
/// Those belong to ``AsyncCogState`` so one declaration can be used safely in
/// multiple isolated contexts and, for ``AsyncCogBox``, at multiple keys.
/// All descriptor access remains MainActor-confined; `Work` is the explicit
/// boundary that permits the selected operation to choose its own isolation.
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
  let lifetime: CogStateLifetime

  /// How a new selection interacts with work already in flight.
  ///
  /// The first slice exposes only `.latest`, so the current state machinery has
  /// no policy branch yet. Keeping the choice on the descriptor makes it part
  /// of the declaration, ready for later policies to remain consistent across
  /// all contexts and keys.
  let policy: LatestPolicy

  /// The total value exposed before this declaration accepts a success.
  ///
  /// Status carries this value through initial loading and initial failure.
  /// Keeping it on the async descriptor gives every context and key the same
  /// declaration-level resting contract without consulting the value projection.
  let defaultValue: Value

  /// Whether two total values should produce the same value-field observation.
  ///
  /// This is the same declaration comparator used by the ordinary async value
  /// projection. Keeping it here lets a `CogStatus.value` UI read receive
  /// exactly the same equality gating without constructing another projection.
  private let equals: (@MainActor (Value, Value) -> Bool)?

  /// Selects one piece of async work while dependency tracking is active.
  ///
  /// The optional erased key lets keyless and boxed declarations share the
  /// runtime call path. ``AsyncCogBox`` installs the adapter that restores its
  /// concrete `Key` before user code runs. Explicit `@MainActor` keeps selector
  /// execution on the graph's actor under every client isolation default.
  private let selector: @MainActor (Reader<CogStatus<Value>>, AnyHashable?) -> Work<Value>

  /// Records the declaration choices shared by every state created from it.
  ///
  /// Construction stores no context and starts no work. State creation remains
  /// lazy in each context and key, preserving independent status and task life.
  init(
    policy: LatestPolicy,
    default defaultValue: Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    selector: @escaping @MainActor (Reader<CogStatus<Value>>, AnyHashable?) -> Work<Value>,
    lifetime: CogStateLifetime = .whileObserved(grace: nil),
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.policy = policy
    self.defaultValue = defaultValue
    self.equals = equals
    self.selector = selector
  }

  /// Whether two total values are equivalent under this declaration's policy.
  ///
  /// A declaration without an equality rule conservatively treats every
  /// publication as a value change, matching its ordinary value projection.
  func valuesAreEqual(_ oldValue: Value, _ newValue: Value) -> Bool {
    equals?(oldValue, newValue) ?? false
  }

  /// Runs the synchronous selector for the state identified by `key`.
  ///
  /// The caller is responsible for opening the tracking scope. This method
  /// returns the description of work to start; it does not launch a task,
  /// publish pending, or mutate status. ``AsyncCogState`` performs those steps
  /// after the selector has returned and its dependency set is complete.
  func makeWork(_ reader: Reader<CogStatus<Value>>, key: AnyHashable?) -> Work<Value> {
    selector(reader, key)
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}
