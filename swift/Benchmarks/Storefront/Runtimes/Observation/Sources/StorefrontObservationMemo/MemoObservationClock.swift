/// The port's injected monotonic clock, and nothing more.
///
/// Deliberately *not* a `Clock` conformance and deliberately not something
/// anything sleeps on. The port's lifetime model is a time-to-live sweep over
/// per-product cache entries, so the only question it ever asks time is "how
/// long since this row was last on screen", and the only thing that moves time
/// is ``advance(by:)``, called from
/// ``MemoObservationStorefrontRuntime/settlingLifetimeRelease(advancingBy:)``,
/// which is the one place the neutral trace is allowed to move a runtime's
/// clock at all.
///
/// A real timer would make the release proof a race: the trace would have to
/// wait for a duration and hope, and a benchmark whose sharpest lifetime
/// checkpoint is a coin flip is worse than one that makes no claim. A counter
/// the port advances on request makes the sweep synchronous and the proof
/// exact.
///
/// ## Identity and isolation
///
/// One instance per runtime, owned by it and shared with nothing. A class
/// rather than a value so the runtime's cells can be stamped against the same
/// reading the sweep later compares them to. MainActor-confined like everything
/// else in this port.
///
/// `nonisolated deinit` per the repository convention: a synthesized deinit
/// under `.defaultIsolation(MainActor.self)` would ask the concurrency runtime
/// which executor it is on for every deallocation.
final class MemoObservationClock {
  /// How far this session's clock has been advanced.
  ///
  /// Starts at zero, which is what a freshly created cell is stamped with, so
  /// a cell demanded during bootstrap and never demanded again is exactly
  /// `now` old.
  private(set) var now: Duration = .zero

  /// Creates a clock resting at zero.
  init() {}

  /// Moves the clock forward.
  ///
  /// - Parameter duration: How far forward. Never negative in this workload;
  ///   the trace only ever advances past a grace period.
  func advance(by duration: Duration) {
    now += duration
  }

  nonisolated deinit {}
}
