/// Counts selector runs from inside the selectors themselves.
///
/// This is deliberately not a diagnostic seam. A scenario increments its own
/// counter in its own closure, using nothing but the public API, so the count
/// stays true across the value-reference and core swaps that COUNT-09 through
/// COUNT-11 require the whole suite to survive. A counter that read Cog's
/// internals would fail exactly the swap it exists to police.
///
/// MainActor-confined because selectors are: the counter is touched only from
/// inside a running selector, never across executors.
@MainActor
public final class CogRunCounter {
  /// How many times the scenario's selectors have run since this counter was
  /// created.
  public private(set) var runs = 0

  /// Creates a counter at zero.
  public init() {}

  /// Records one selector run.
  ///
  /// Call this as the first statement of a selector body, before any read, so
  /// a run that traps or returns early still counts. Cog runs a selector at
  /// most once per settle, so one call per body is one run.
  public func record() {
    runs += 1
  }
}
