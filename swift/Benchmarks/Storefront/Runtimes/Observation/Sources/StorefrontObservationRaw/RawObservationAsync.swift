public import StorefrontWorkload
import os

/// Which asynchronous value a piece of request bookkeeping belongs to.
///
/// One case per asynchronous declaration in the Cog port, with the keyed ones
/// carrying their product. It is deliberately *not* ``StorefrontRequestID``:
/// a request identity is what the service is asked for and changes whenever the
/// inputs change, whereas a slot is the cell that identity is asked *on* and is
/// stable for the life of the session. Keeping the two apart is what lets the
/// port notice that `.searchIndex`, whose request identity carries no inputs at
/// all, must nevertheless be asked again once a different catalog has landed.
///
/// `nonisolated` and `Hashable` because it is a dictionary key on the MainActor
/// and nothing more; it carries no state of its own.
nonisolated enum RawObservationAsyncSlot: Hashable {
  /// The catalog at the root of the browse graph.
  case catalog
  /// The account response.
  case account
  /// The inverted search index over the accepted catalog.
  case searchIndex
  /// Suggestions for the current normalized query.
  case suggestions
  /// Personalized recommendations for the signed-in shopper.
  case recommendations
  /// Live inventory for one product.
  case inventory(ProductID)
  /// The personalized offer for one product.
  case offer(ProductID)
  /// The detail payload for one product.
  case detail(ProductID)
  /// The shipping quote for the settled cart.
  case shippingQuote
  /// The tax quote for the settled cart.
  case taxQuote
}

/// Everything one slot's current demand depends on.
///
/// The request identity plus the dependency values that identity does not
/// already carry. Comparing this against what a slot last asked for is the
/// port's **request-identity cache**, and it is the single caching carve-out the
/// raw port takes: without it the port would spin, render, request, publish,
/// render, request, because it has no other way to tell "this is the same
/// question I already asked" from "the world moved". Nobody re-fires a network
/// request on every frame, so a port that did would be measuring a defect rather
/// than a floor. It caches no *derived value*; every synchronous derivation is
/// still recomputed on every read.
///
/// The epochs are counters the runtime advances when an upstream *accepted
/// response* actually changes, which is how a hand-written app decides whether
/// a derived resource has to be fetched again, `didAcceptCatalog`, spelled as
/// a number so it can be compared rather than remembered.
nonisolated struct RawObservationAsyncDemand: Hashable {
  /// What the service would be asked for.
  let request: StorefrontRequestID

  /// Which accepted catalog this demand was computed against.
  ///
  /// Zero for a slot that does not read the catalog. The search index, the
  /// suggestions, the recommendations, and a detail payload all do, and none of
  /// their request identities mention it.
  let catalogEpoch: Int

  /// Which signed-in shopper this demand was computed against.
  ///
  /// Zero for a slot that does not read the shopper. An offer's request
  /// identity is only the product, so signing in has to move this instead.
  let shopperEpoch: Int

  /// The cart lines this demand was computed against.
  ///
  /// Empty for a slot that is not a quote. Two carts can produce the same
  /// discounted subtotal, market, and method, the whole of a quote's request
  /// identity, while containing a different number of lines, which a shipping
  /// quote prices differently.
  let cartLineIDs: [ProductID]

  /// How many times the demand for this slot has been re-asked explicitly.
  ///
  /// What makes ``StorefrontRuntime/refreshCatalog()`` and its siblings ask
  /// again even though nothing about the world changed.
  let refreshEpoch: Int

  /// Records one slot's current demand.
  ///
  /// Every dependency parameter defaults to "does not depend on this", so each
  /// call site names exactly the inputs its Cog counterpart reads and a reader
  /// can see the dependency list at the point of demand.
  ///
  /// - Parameters:
  ///   - request: What the service would be asked for.
  ///   - catalogEpoch: Which accepted catalog this was computed against.
  ///   - shopperEpoch: Which signed-in shopper this was computed against.
  ///   - cartLineIDs: The cart lines this was computed against.
  ///   - refreshEpoch: How many times this slot has been re-asked explicitly.
  init(
    request: StorefrontRequestID,
    catalogEpoch: Int = 0,
    shopperEpoch: Int = 0,
    cartLineIDs: [ProductID] = [],
    refreshEpoch: Int
  ) {
    self.request = request
    self.catalogEpoch = catalogEpoch
    self.shopperEpoch = shopperEpoch
    self.cartLineIDs = cartLineIDs
    self.refreshEpoch = refreshEpoch
  }
}

/// One slot's request bookkeeping.
///
/// Deliberately not on ``RawObservationStorefrontModel``: a generation counter
/// and a demand key are plumbing, not state a screen renders, and putting them
/// on the observable model would make an accounting write look like a change to
/// the world.
nonisolated struct RawObservationAsyncRecord {
  /// What this slot last asked for, or `nil` when it is resting on a
  /// short-circuit guard and has asked for nothing.
  var demand: RawObservationAsyncDemand?

  /// Which generation of this slot's demand is current.
  ///
  /// Advanced whenever the demand changes. A completed response carries the
  /// generation captured synchronously when it was selected, and is published
  /// only when the two still agree, which is how this port refuses a stale
  /// result **by generation** rather than by relying on task cancellation.
  /// ``StorefrontScript`` leaves cancelled requests suspended by default
  /// precisely so that a port relying on cancellation would fail rather than
  /// pass by accident.
  var generation = 0

  /// How many times this slot's demand has been re-asked explicitly.
  var refreshEpoch = 0
}

/// One generation of the raw port's recommendation demand.
///
/// Resolved by the runtime on the MainActor and awaited from wherever the
/// handle ended up, so the outcome is stored under a lock rather than behind an
/// isolation boundary. Replacement resolves it as
/// ``StorefrontRefreshOutcome/superseded`` at the moment of replacement, which
/// is what makes the teardown phase's checkpoint a definite signal rather than
/// a timeout: the trace never waits on a duration.
///
/// ## Identity and ownership
///
/// One instance per demand. The runtime retains the newest unresolved handle so
/// that the next demand can supersede it, and drops that reference as soon as it
/// resolves; the caller may hold its own handle for as long as it likes.
///
/// ## Ordering
///
/// A resolved outcome is retained, so awaiting after the runtime has long moved
/// on still answers about the generation this handle names, and awaiting twice
/// answers twice. Resolution is one-shot: a second resolve is ignored rather
/// than overwriting, because a handle that changed its mind would make the
/// checkpoint unfalsifiable.
///
/// `nonisolated deinit` per the repository convention.
public nonisolated final class RawObservationStorefrontRefresh: StorefrontRefreshHandle {
  /// What this generation produced.
  public typealias Value = [ProductID]

  /// The outcome and everyone waiting for it.
  private struct State {
    /// The terminal outcome, once the runtime has decided.
    var outcome: StorefrontRefreshOutcome<[ProductID]>?

    /// Waiters suspended before the decision arrived.
    var waiters: [CheckedContinuation<StorefrontRefreshOutcome<[ProductID]>, Never>] = []
  }

  /// The lock-protected state.
  ///
  /// An unfair lock rather than an actor because resolution happens inside the
  /// runtime's synchronous MainActor epilogue, and an actor hop there would let
  /// the trace observe a replacement that had not been recorded yet.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates an unresolved handle.
  init() {}

  /// Creates a handle that has already decided.
  ///
  /// Used when a demand short-circuits, a signed-out shopper has no
  /// recommendations to fetch, so that the caller still receives a handle whose
  /// outcome resolves rather than one that hangs.
  ///
  /// - Parameter resolved: The outcome this handle was born with.
  init(resolved: StorefrontRefreshOutcome<[ProductID]>) {
    state.withLock { $0.outcome = resolved }
  }

  /// Records this generation's terminal outcome and wakes every waiter.
  ///
  /// Ignores a second call: the first decision is the one this generation made.
  ///
  /// - Parameter outcome: What this generation produced.
  func resolve(_ outcome: StorefrontRefreshOutcome<[ProductID]>) {
    let waiters = state.withLock {
      state -> [CheckedContinuation<StorefrontRefreshOutcome<[ProductID]>, Never>] in
      guard state.outcome == nil else { return [] }
      state.outcome = outcome
      let waiters = state.waiters
      state.waiters = []
      return waiters
    }
    for waiter in waiters { waiter.resume(returning: outcome) }
  }

  /// The terminal result of this exact generation.
  ///
  /// Resolves without a clock and without a poll.
  public var outcome: StorefrontRefreshOutcome<[ProductID]> {
    get async {
      await withCheckedContinuation { continuation in
        let resolved = state.withLock { state -> StorefrontRefreshOutcome<[ProductID]>? in
          if let outcome = state.outcome { return outcome }
          state.waiters.append(continuation)
          return nil
        }
        if let resolved { continuation.resume(returning: resolved) }
      }
    }
  }

  nonisolated deinit {}
}
