/// A per-key release signal for scope proofs, with no ordering assumptions.
///
/// Cancellation-resistant work has to wait for the test rather than for
/// cancellation, and several lifetimes are usually in flight at once. One
/// `AsyncStream` cannot serve them: separate iterators over one stream compete
/// for the same elements, so a release meant for the retired lifetime can be
/// consumed by its replacement.
///
/// This gate keys the signal instead. Each waiter names the lifetime it belongs
/// to, and a release delivered before its waiter arrives is remembered rather
/// than lost, so a test never has to sleep, poll, or guess at task startup
/// order.
@MainActor
final class ScopeTestGate {
  /// Waiters suspended on a key that has not been released yet.
  private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

  /// Keys released before anyone waited on them.
  private var releasedEarly: Set<Int> = []

  /// Creates a gate with nothing waiting and nothing released.
  init() {}

  /// Suspends until `key` is released, returning at once if it already was.
  func wait(_ key: Int) async {
    if releasedEarly.remove(key) != nil { return }
    await withCheckedContinuation { continuation in
      waiting[key] = continuation
    }
  }

  /// Releases one key's waiter, or records the release for a waiter to come.
  func release(_ key: Int) {
    if let continuation = waiting.removeValue(forKey: key) {
      continuation.resume()
      return
    }
    releasedEarly.insert(key)
  }
}
