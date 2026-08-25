internal import StorefrontWorkload

/// One asynchronous value the port keeps, and everything it needs to decide
/// whether to ask the service again.
///
/// The port's asynchronous layer is a store of these — one per asynchronous
/// identity in the Cog port's ten asynchronous declarations, keyed by product
/// where the Cog declaration is keyed by product. A cell is created lazily on
/// first demand, because a cell that exists for a product no screen has ever
/// shown is exactly the eager materialization the workload exists to measure
/// the absence of.
///
/// ## Reads are total
///
/// ``value`` is the last accepted success, resting on the declaration's default
/// until one exists. A read never surfaces a loading case, because a loading
/// case would change what a screen depends on and therefore what re-renders —
/// the Cog port keeps uncertainty in a separate status lens for the same
/// reason, and a port that leaked it into the rendered value would be running a
/// different workload.
///
/// ## Why a request-identity cache is allowed here
///
/// It is the one carve-out the comparison grants both `@Observable` ports, and
/// it is stated rather than assumed. Nobody re-fires a network request on every
/// frame; without ``satisfiedKey`` and ``pendingKey`` the port would spin —
/// render, request, publish, render, request — and measure a defect. What it is
/// *not* is a memoization of derived work: no synchronous computation is cached
/// here, only the fact that a particular request has been asked or answered.
///
/// ## Generations
///
/// ``generation`` is bumped every time the port starts a request for this cell
/// and every time the cell is dropped. A completing task carries the generation
/// it was launched with, and the epilogue compares the two: equal means accept,
/// different means the selection moved on and the result is refused. That is a
/// refusal by generation, never by task cancellation — the scripted request
/// boundary leaves cancelled requests suspended by default precisely so a port
/// cannot pass the stale-result checkpoint by accident.
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
  /// a settled screen from re-asking for something it already has — and what
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

  /// Whether an input this cell's request is *computed from* — rather than
  /// keyed on — has changed since the last launch.
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
