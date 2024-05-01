/// Enumerates all concurrent value recalculation strategies supported by
/// asynchronous automatic Cogs.
enum Async {
  /// Concurrency strategy that permits multiple value calculations to occur at
  /// a time, ensuring that only the value resulting from **latest value
  /// calculation to begin** is committed.
  parallelLatestWins,

  /// Concurrency strategy that permits multiple value calculations to occur at
  /// a time, keeping the result.
  ///
  /// This is the default concurrency strategy. It is also the simplest.
  parallelUnordered,

  /// Concurrency strategy that permits only one value calculation to occur at a
  /// time by ignoring all new requests for value calculation while value
  /// calculation is already in progress.
  sequentialIgnoring,

  /// Concurrency strategy that permits only one value calculation to occur at a
  /// time by deferring the next value calculation until the current value
  /// calculation finishes.
  sequentialQueued,
}

/// Default [Async] used by Cogs.
const defaultAsync = Async.parallelUnordered;
