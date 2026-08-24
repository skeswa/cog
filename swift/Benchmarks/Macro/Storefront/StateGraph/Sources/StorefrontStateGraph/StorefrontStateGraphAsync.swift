public import StorefrontWorkload
internal import os

// The port-authored asynchronous layer, and the reason it has to exist.
//
// swift-state-graph 0.28.0 supplies no async node primitive comparable to
// Cog's `Async`. `Node.observe()` is an `AsyncSequence` for *consuming*
// changes and `GraphUserDefault` is an unrelated persistence bridge; the
// complete public surface of the `StateGraph` module was enumerated for
// `API-NOTES.md` §6 and there is nothing else. So this file is the port's own
// answer to the four questions Cog's `Async` answers for it: what identifies a
// request, when does a new one supersede the one in flight, which completions
// are accepted, and what does a caller await while one is outstanding.
//
// Everything here is ordinary Swift. None of it is measured *as* the library,
// and `docs/swift/impl/perf.md` says so in one sentence: the cost of
// this plumbing sits inside the state-graph runtime's numbers because a
// storefront that cannot await anything is not a storefront, not because
// swift-state-graph is being blamed for lacking it.

/// One asynchronous identity in the Storefront graph.
///
/// Ten cases for the ten `Cog.Async` and `CogBox.Async` declarations in
/// `swift/Benchmarks/Macro/Storefront/Workload/Sources/CogStorefront/StorefrontAsync.swift`, keyed the
/// same way they are: seven keyless, three per product. This is the key of the
/// port's own slot table, not of anything the library provides — 0.28.0 has no
/// keyed-node facility at all (`NodeStore` is a weak, `DEBUG`-only `graphViz`
/// aid), so the table and everything it costs belong to the port.
///
/// `Hashable` because it is a dictionary key and `Sendable` because a request
/// task carries it back to the MainActor when it completes.
nonisolated enum StorefrontStateGraphAsyncKey: Hashable, Sendable {
  /// The catalog, at the root of the browse half of the graph.
  case catalog
  /// The signed-in shopper's account.
  case account
  /// The inverted search index over the accepted catalog.
  case searchIndex
  /// Suggestions for the normalized query.
  case suggestions
  /// Personalized recommendations for the signed-in shopper.
  case recommendations
  /// The shipping quote for the settled cart.
  case shippingQuote
  /// The tax quote for the settled cart.
  case taxQuote
  /// Live inventory for one product.
  case inventory(ProductID)
  /// The personalized offer for one product.
  case offer(ProductID)
  /// The detail payload for one product.
  case detail(ProductID)
}

/// What one asynchronous slot would ask for, given the graph as it stands.
///
/// The port's stand-in for Cog's async *selector*, and the shape is chosen for
/// one measured reason. A Cog selector is a graph node: it re-runs when any
/// dependency is invalidated, and every re-run is a new generation. Reproducing
/// that here means the plan must change exactly when Cog's selector would have
/// re-selected — including the case that has nothing to do with the request's
/// name, where a fresh catalog makes the search index ask the same
/// ``StorefrontRequestID/searchIndex`` question about different products.
///
/// So a plan carries the *inputs* that decide the answer, not merely the
/// request's identity. It carries them cheaply: bulky inputs appear as a
/// revision counter the port bumps when it publishes a genuinely different
/// value, never as the `[Product]` array itself. The plan is compared on every
/// poll of every demanded slot — tens of comparisons per user action — and an
/// array comparison there would put a thousand-element `==` in the hot path of
/// a benchmark whose whole subject is invalidation cost. The payload each
/// request actually needs is captured when the request starts, exactly as a
/// Cog selector captures its dependencies synchronously before handing back
/// `.run { @concurrent … }`.
///
/// `Hashable` for the same reason ``StorefrontRequestID`` is: a plan a port can
/// only compare approximately is a plan that starts duplicate work.
nonisolated enum StorefrontStateGraphPlan: Hashable, Sendable {
  /// The selector short-circuited: publish the declaration's resting value and
  /// ask for nothing.
  ///
  /// The five guard branches Cog's declarations spell as `return .run { … }` —
  /// an empty query, a signed-out shopper, an empty cart, an unknown product —
  /// all land here. They publish and schedule nothing, which is what keeps the
  /// bootstrap phase's "exactly three root requests" checkpoint true.
  case resting
  /// The catalog. No inputs, so it is selected once per session and afterwards
  /// only by an explicit ``StorefrontRuntime/refreshCatalog()``.
  case catalog
  /// The account. Same shape as ``catalog``.
  case account
  /// The search index over the catalog at `catalogRevision`.
  case searchIndex(catalogRevision: Int)
  /// Suggestions for one exact normalized query over one catalog revision.
  case suggestions(query: String, catalogRevision: Int)
  /// Recommendations for one account over one catalog revision.
  case recommendations(accountID: Int, catalogRevision: Int)
  /// Inventory for one product at one generation.
  case inventory(id: ProductID, generation: Int)
  /// The offer for one product and one account.
  case offer(id: ProductID, accountID: Int)
  /// The detail payload for one product in one catalog revision.
  case detail(id: ProductID, catalogRevision: Int)
  /// A shipping quote for one settled cart shape.
  case shippingQuote(
    subtotalCents: Int,
    address: ShippingAddress,
    method: ShippingMethod,
    lineCount: Int
  )
  /// A tax quote for one settled cart shape.
  case taxQuote(subtotalCents: Int, address: ShippingAddress)
}

/// One asynchronous slot's bookkeeping, which is deliberately not in the graph.
///
/// Cog keeps a generation and an in-flight identity inside its async state;
/// this port keeps them beside the graph instead, and the difference is
/// measurable rather than stylistic. A `Stored<AsyncCell<Value>>` holding the
/// value *and* the generation would invalidate every reader of the value each
/// time a generation advanced — so an inventory burst that only made readings
/// stale would re-render every row it touched, and the burst phase's central
/// claim would be lost to bookkeeping. The graph therefore holds the accepted
/// *value* alone, in an equality-gated `Stored`, exactly as Cog's value read
/// sees it; generation, plan, and demand stamp live here.
nonisolated struct StorefrontStateGraphSlot {
  /// How many times this slot has been selected.
  ///
  /// Starts at zero, which reads as "never selected": the first poll advances
  /// it to one. A completion is accepted only when it names the generation the
  /// slot is currently on, which is what makes staleness a refusal by
  /// generation rather than a reliance on task cancellation — the request
  /// script leaves cancelled requests suspended precisely so a port cannot
  /// pass the stale-result checkpoint by accident.
  var generation = 0

  /// The plan this slot's current generation was selected for, or `nil` before
  /// the first selection.
  var plan: StorefrontStateGraphPlan?

  /// When this slot was last demanded, on the runtime's injected clock.
  ///
  /// Only per-product slots are ever released, and only past grace; see
  /// `StateGraphStorefrontRuntime.settlingLifetimeRelease(advancingBy:)`.
  var lastDemandedAt: Duration = .zero
}

/// A one-shot, thread-safe resolution cell for one exact demand generation.
///
/// The port's answer to `CogRefresh`. It exists because
/// ``StorefrontRefreshHandle`` promises something a plain `Task` cannot give:
/// a *definite* signal at the moment a generation is replaced, without a clock,
/// a poll, or a timeout. The teardown phase's superseded-refresh checkpoint
/// awaits exactly that on the line after the replacing call, so the resolution
/// has to happen when the runtime advances the slot's generation — not when the
/// abandoned task eventually finishes, which in this script it never does.
///
/// ## Identity and ownership
///
/// One instance per `refreshRecommendations()` call, retained by the runtime's
/// generation table until it resolves and by whatever holds the handle
/// afterwards. Resolution is idempotent and first-writer-wins, so the two paths
/// that can resolve it — replacement, and the completion of the generation it
/// names — cannot fight: whichever happens first is the answer, and the other
/// is a no-op rather than a trap.
///
/// ## Isolation
///
/// `nonisolated` and `Sendable` so a handle may be awaited from a task that is
/// not the MainActor, while every resolution happens on the MainActor because
/// every publish-or-discard decision does. The lock protects only the handoff
/// between those two sides.
///
/// `nonisolated deinit` per the repository convention: under
/// `.defaultIsolation(MainActor.self)` a synthesized deinit would ask the
/// concurrency runtime which executor it is on for every deallocation.
nonisolated final class StorefrontStateGraphRefreshPromise: Sendable {
  /// Whether the outcome has arrived, and who is waiting for it if not.
  private enum State {
    /// Nobody has resolved this generation and nobody is waiting.
    case pending
    /// One waiter is suspended on this generation.
    case waiting(CheckedContinuation<StorefrontRefreshOutcome<[ProductID]>, Never>)
    /// The generation resolved, and the outcome is retained for later readers.
    case resolved(StorefrontRefreshOutcome<[ProductID]>)
  }

  /// The handoff between the resolving MainActor and the awaiting task.
  private let state = OSAllocatedUnfairLock<State>(initialState: .pending)

  /// Creates an unresolved promise.
  init() {}

  /// Resolves this generation, resuming a waiter if one is suspended.
  ///
  /// Idempotent on purpose. A generation can be superseded by replacement and
  /// then also complete on the wire; both paths call this, and the first one
  /// is the truth. Trapping on the second would turn a perfectly ordinary race
  /// between a scripted release and a replacement into a crash.
  ///
  /// - Parameter outcome: What this generation produced.
  func resolve(_ outcome: StorefrontRefreshOutcome<[ProductID]>) {
    let waiter: CheckedContinuation<StorefrontRefreshOutcome<[ProductID]>, Never>? =
      state.withLock { state in
        switch state {
        case .resolved:
          return nil
        case .pending:
          state = .resolved(outcome)
          return nil
        case .waiting(let continuation):
          state = .resolved(outcome)
          return continuation
        }
      }
    waiter?.resume(returning: outcome)
  }

  /// The terminal result of this exact generation.
  ///
  /// Returns immediately when the generation has already resolved, so awaiting
  /// after the runtime has long moved on is safe and still answers about the
  /// generation this promise names. Only one waiter is supported, which is all
  /// the protocol needs; a second concurrent waiter would replace the first and
  /// is a programmer error rather than a supported shape.
  var outcome: StorefrontRefreshOutcome<[ProductID]> {
    get async {
      let resolved: StorefrontRefreshOutcome<[ProductID]>? = state.withLock { state in
        if case .resolved(let outcome) = state { return outcome }
        return nil
      }
      if let resolved { return resolved }
      return await withCheckedContinuation { continuation in
        let immediate: StorefrontRefreshOutcome<[ProductID]>? = state.withLock { state in
          switch state {
          case .resolved(let outcome):
            return outcome
          case .pending, .waiting:
            state = .waiting(continuation)
            return nil
          }
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    }
  }

  nonisolated deinit {}
}

/// The port's per-generation recommendation demand handle, in neutral
/// vocabulary.
///
/// A thin `struct` around ``StorefrontStateGraphRefreshPromise`` for the same
/// reason `CogStorefrontRefresh` is a thin struct around `CogRefresh`: the
/// translation into ``StorefrontRefreshOutcome`` belongs in one visible place,
/// and `StorefrontWorkload` must stay free of any runtime's own vocabulary.
///
/// `Sendable` because ``StorefrontRefreshHandle`` is: a handle may be awaited
/// from a task other than the one that created it, and the runtime resolves the
/// underlying promise on the MainActor.
public nonisolated struct StateGraphStorefrontRefresh: StorefrontRefreshHandle {
  /// What this generation produced.
  public typealias Value = [ProductID]

  /// The promise bound to exactly one generation.
  private let promise: StorefrontStateGraphRefreshPromise

  /// Wraps one generation's promise.
  ///
  /// - Parameter promise: The promise the runtime registered for the
  ///   generation this call started. It never drifts to a later one.
  init(promise: StorefrontStateGraphRefreshPromise) {
    self.promise = promise
  }

  /// The terminal result of this exact generation.
  ///
  /// Resolves without a clock and without a poll: replacement resolves it as
  /// ``StorefrontRefreshOutcome/superseded`` at the moment the runtime advances
  /// the slot's generation, and a lifetime release resolves it as
  /// ``StorefrontRefreshOutcome/released``.
  public var outcome: StorefrontRefreshOutcome<[ProductID]> {
    get async { await promise.outcome }
  }
}
