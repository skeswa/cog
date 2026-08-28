import CogStorefront
import StorefrontWorkload

/// Which rows the browse list currently has materialized.
///
/// This is platform-ephemeral UI state and deliberately not graph state. The
/// facts it holds, the lowest and highest flat row index SwiftUI has realized
///, are produced by the list's own layout, are meaningless the moment the
/// screen goes away, and have exactly one consumer: the ``CogOps/scrollRows(to:)``
/// op that tells the graph which rows to demand data for. The graph owns the
/// window; this type owns the accounting that produces it.
///
/// It is a **class held in `@State`** rather than two `@State` integers, and
/// that is the entire design. Two `@State` integers would invalidate the browse
/// screen's `body` on every row that scrolled into view, rebuilding the
/// section list, and turning a scroll into a per-frame rebuild of the very view
/// under measurement. Mutating a property of a reference held in `@State`
/// notifies nobody, which is exactly what a scroll-position ledger should do.
///
/// The bounds are maintained by the standard linear-list heuristic: a list
/// scrolls in one dimension, so a row leaving at the low end can only be the
/// current minimum and a row leaving at the high end can only be the current
/// maximum. ``reset()`` restores the empty state when the screen's content
/// changes underneath it.
///
/// `nonisolated deinit` because every class in this repository declares one:
/// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a synthesized `deinit`
/// asks the concurrency runtime which executor it is on for every single
/// deallocation.
@MainActor
final class StorefrontRowWindowTracker {
  /// The lowest realized flat row index, or `nil` when nothing is realized.
  private(set) var firstVisibleRow: Int?

  /// The highest realized flat row index, or `nil` when nothing is realized.
  private(set) var lastVisibleRow: Int?

  /// The window most recently handed to the graph.
  ///
  /// Kept so a realization that does not move either bound produces no turn at
  /// all. A list re-realizing the same rows is not a scroll, and publishing an
  /// identical window would be a turn whose only effect is to cost one.
  private var committedWindow = RowWindow(offset: 0, length: 0)

  /// Creates an empty tracker.
  init() {}

  /// Records that a row was realized.
  ///
  /// - Parameter index: The row's flat index across every section.
  /// - Returns: The new window when it moved, and `nil` when it did not.
  func rowAppeared(_ index: Int) -> RowWindow? {
    firstVisibleRow = Swift.min(firstVisibleRow ?? index, index)
    lastVisibleRow = Swift.max(lastVisibleRow ?? index, index)
    return changedWindow()
  }

  /// Records that a row was discarded.
  ///
  /// - Parameter index: The row's flat index across every section.
  /// - Returns: The new window when it moved, and `nil` when it did not.
  func rowDisappeared(_ index: Int) -> RowWindow? {
    guard let first = firstVisibleRow, let last = lastVisibleRow else { return nil }
    if first == last, first == index {
      firstVisibleRow = nil
      lastVisibleRow = nil
    } else if index <= first {
      firstVisibleRow = first + 1
    } else if index >= last {
      lastVisibleRow = last - 1
    }
    return changedWindow()
  }

  /// Forgets every realized row.
  ///
  /// Called when the list's content changes, because a flat index means
  /// something different after a filter than it did before it, and carrying the
  /// old bounds across would describe a window that no longer exists.
  ///
  /// - Returns: The new window when it moved, and `nil` when it did not.
  func reset() -> RowWindow? {
    firstVisibleRow = nil
    lastVisibleRow = nil
    return changedWindow()
  }

  /// The current window, or `nil` when it matches the last one published.
  private func changedWindow() -> RowWindow? {
    let window: RowWindow
    if let first = firstVisibleRow, let last = lastVisibleRow, last >= first {
      window = RowWindow(offset: first, length: last - first + 1)
    } else {
      window = RowWindow(offset: 0, length: 0)
    }
    guard window != committedWindow else { return nil }
    committedWindow = window
    return window
  }

  nonisolated deinit {}
}
