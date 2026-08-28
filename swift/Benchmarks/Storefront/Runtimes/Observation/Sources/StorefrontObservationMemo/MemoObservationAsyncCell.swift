internal import StorefrontWorkload

/// One asynchronous value the port keeps, and everything it needs to decide
/// whether to ask the service again.
///
/// The async layer stores one cell per demanded identity in Cog's ten async
/// declarations. Product-keyed work uses product-keyed cells. Lazy creation
/// avoids state for products no screen has shown.
///
/// ## Reads are total
///
/// ``value`` holds the last success or the declaration default. Reads never
/// expose loading because that would change screen dependencies and renders.
/// Cog also keeps request status separate from the rendered value.
///
/// ## Why a request-identity cache is allowed here
///
/// Both `@Observable` ports may cache request identity. Without ``satisfiedKey``
/// and ``pendingKey``, each frame would repeat the request. This caches no
/// derived computation, only whether a request was asked or answered.
///
/// ## Generations
///
/// Starting a request or dropping the cell increments ``generation``. A result
/// is accepted only when its launch generation still matches. The scripted
/// service keeps cancelled work suspended, so cancellation cannot hide a stale
/// result bug.
///
/// A value type, so a cell is copied out of its dictionary, mutated, and
/// written back. Nothing observes a cell; the port's hand-written invalidation
/// decides what a completion invalidates.
struct MemoObservationAsyncCell<Value> {
  /// The last accepted success, or the declaration's resting default.
  var value: Value

  /// The request identity whose response ``value`` came from, or `nil` when no
  /// response has been accepted.
  ///
  /// Comparing this with the identity the current sources imply is what stops
  /// a settled screen from re-asking for something it already has, and what
  /// makes "no duplicate inventory work" provable rather than hoped for.
  var satisfiedKey: StorefrontRequestID?

  /// The request identity currently in flight, or `nil` when nothing is.
  var pendingKey: StorefrontRequestID?

  /// Which launch this cell is on.
  ///
  /// Monotonic per cell, and never compared across cells: it exists only so a
  /// completing task can ask "am I still the current attempt for this one
  /// value", which is a different question from anything a dependency graph
  /// asks.
  var generation = 0

  /// Whether an input this cell's request is *computed from*, rather than
  /// keyed on, has changed since the last launch.
  ///
  /// Three of the workload's requests are keyed on an identity that does not
  /// mention every input the response depends on: the search index is
  /// `.searchIndex` however many catalogs it has been built over,
  /// recommendations are keyed on the account alone, and suggestions on the
  /// query alone. For those, the identity comparison above cannot notice that
  /// the catalog or the shopper moved, so the hand-written invalidation says so
  /// explicitly by setting this flag. Cleared when the next request launches.
  var needsRefetch = false

  /// When this cell was last demanded, on the port's own injected clock.
  ///
  /// Only per-product cells are swept, and only against this stamp; see
  /// ``MemoObservationClock``.
  var lastDemandedAt: Duration = .zero

  /// Creates a cell resting on a declaration's default.
  ///
  /// - Parameter value: The resting value a read returns until a response is
  ///   accepted.
  init(value: Value) {
    self.value = value
  }

  /// Whether a request for `key` is already answered or already in flight.
  ///
  /// - Parameter key: The identity the current sources imply.
  /// - Returns: Whether asking again would be duplicate work.
  func isSatisfied(by key: StorefrontRequestID) -> Bool {
    !needsRefetch && (satisfiedKey == key || pendingKey == key)
  }
}
