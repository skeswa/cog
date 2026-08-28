internal import Observation
public import StorefrontWorkload

/// The hand-memoized `@Observable` implementation of the Storefront workload.
///
/// The realistic competitor: what a competent team ships when it has
/// `@Observable`, cares about performance, and has no reactive library. Plain
/// stored properties for state, a handful of hand-chosen caches for the
/// expensive derivations, and an explicitly enumerated list of which caches each
/// setter clears.
///
/// ## What this port is, and what it deliberately is not
///
/// It is **not** a re-implementation of Cog. It has no reader that records what
/// it read, no dependency graph, no automatic transitive invalidation, no
/// version stamps propagated between values, and no settlement algorithm.
/// Invalidation is a list of hand-written methods,
/// `didWriteCoupon()`, `didAcceptCatalog()`, `didChangeProduct(_:pricingAffected:)`
///, that a person wrote and a person would have to maintain. Every one of them
/// lives in `MemoObservationInvalidation.swift` so a reader can count the lines
/// and judge how much hand-maintenance the resulting numbers cost. That count is
/// the honest denominator of this comparison, and it is recorded in the port's
/// `README.md` and in `docs/swift/impl/perf.md`.
///
/// The single most important granularity decision is the pricing ladder: it is
/// memoized as **one cell per product**, not as seventeen per-policy stages.
/// Cog gets stage granularity for free from declared dependencies, changing the
/// coupon dirties the coupon stage and everything below it and nothing above it.
/// Reproducing that by hand would mean maintaining seventeen invalidation lists
/// per product in the one place this workload is deliberately deepest, which is
/// both a re-implementation of the thing under comparison and not what anyone
/// writes. So this port recomputes a product's whole ladder when any of that
/// product's pricing inputs move, and the results table says so in a sentence.
///
/// ## Identity and ownership
///
/// One instance per session, created by
/// ``make(profile:service:initialWindow:holds:sink:grace:)`` and retained by the
/// driver. It owns the model, every cache, every asynchronous cell, and its own
/// injected clock; the driver owns the script, the sink, and the shadow world.
///
/// ## Isolation
///
/// MainActor-confined. Every verb writes on the MainActor, every cache is built
/// there, and every publish-or-discard decision is made there. Heavy request
/// work runs off the MainActor, the request boundary's kernels are the largest
/// computations in the workload, and only the decision returns.
///
/// ## Turn and settlement ordering
///
/// Every verb is one ``mutate(_:)``: rendering is suppressed, the body writes
/// plain stored properties and calls the invalidation methods those writes
/// imply, and the close renders **once**, running only the observers whose dirty
/// flag is set. Reads inside a verb see that verb's own staged writes for free,
/// because they are plain stored properties. A verb returns settled, which is
/// what lets the trace read the sink on the very next line.
///
/// Rendering is port-owned rather than driven by Observation's change callback.
/// That is a **deviation from what a SwiftUI application does**, and it is
/// stated rather than hidden: `withObservationTracking`'s callback fires before
/// the mutation has completed, and re-registering afterwards is a scheduling
/// decision, not a settlement. A port that scheduled its render would not be
/// running the same script as the other three runtimes, because the trace reads
/// the sink synchronously. The registrar's registration cost is still paid,
/// every observer body runs inside a tracking scope, so what the deviation
/// removes is the scheduling, not the cost.
///
/// ## Observation
///
/// The observers named by `holds` are registered once in `make` and run there
/// once each. After that an observer runs exactly when a hand-written
/// invalidation method sets its dirty flag, which is this port's whole claim: it
/// should be behaviorally indistinguishable from Cog at the checkpoint level,
/// and the comparison should therefore be purely about cost and about how much
/// hand-written invalidation it took.
///
/// ## Cancellation and races
///
/// Asynchronous results are accepted or refused by comparing the generation a
/// task was launched with against the cell's current generation, captured
/// synchronously at selection time. Superseded tasks are **not** cancelled, and
/// that is deliberate in both directions: the scripted request boundary leaves
/// cancelled requests suspended by default, so cancellation could not be the
/// correctness mechanism anyway, and letting a superseded task complete when the
/// driver releases it keeps the one-release-one-decision accounting the
/// completion barrier depends on exact.
///
/// `nonisolated deinit` per the repository convention: under
/// `.defaultIsolation(MainActor.self)` a synthesized deinit would ask the
/// concurrency runtime which executor it is on for every deallocation.
public final class MemoObservationStorefrontRuntime: StorefrontRuntime {
  /// The per-generation demand handle this runtime hands back.
  public typealias Refresh = MemoObservationRefresh

  /// What this runtime is called in a benchmark name, and what it guarantees.
  ///
  /// Every value matches the Cog port. Hand-written caching and invalidation can
  /// reproduce a fine-grained graph's visible behavior. The port's `README.md`
  /// supports each claim:
  ///
  /// - One `mutate` renders once, so a changing transaction runs browse once.
  /// - Setters gate equality before mutation, so equal writes run nothing.
  /// - `didChangeProduct` checks demand, so offscreen input runs nothing.
  /// - Sign-in runs the account observer at registration and acceptance.
  /// - Explicit demand starts no service work for offscreen-only changes.
  /// - A clock-driven sweep releases unobserved per-product cache entries.
  /// - Generations reject stale results without relying on cancellation.
  /// - Each demand returns a handle for its exact generation.
  public static let descriptor = StorefrontRuntimeDescriptor(
    slug: "observation-memo",
    displayName: "hand-memoized @Observable",
    semantics: StorefrontRuntimeSemantics(
      browseRunsPerContentChangingTurn: 1,
      browseRunsPerEqualWrite: 0,
      browseRunsPerUndemandedInvalidation: 0,
      accountRunsThroughSignIn: 2,
      declaredUndemandedRequestStarts: 0,
      releasesUnobservedValues: true,
      refusesStaleResultsByGeneration: true,
      hasPerGenerationRefreshHandles: true
    )
  )

  // MARK: - Session

  /// The world's size. Fixed for the session.
  let profile: StorefrontProfile

  /// The installed request boundary.
  ///
  /// Every asynchronous selection goes through this exact instance and calls
  /// ``StorefrontService/schedule(_:)`` synchronously, on the MainActor, before
  /// launching its task.
  let service: StorefrontService

  /// Which durable observers this session registered.
  let holds: StorefrontHolds

  /// Where those observers deposit what they read and count their own runs.
  let sink: StorefrontSink

  /// How long a per-product cache entry may survive with nothing demanding it.
  let grace: Duration

  /// The clock the time-to-live sweep measures against.
  let clock = MemoObservationClock()

  /// Every writable fact this port owns.
  let model = MemoObservationStorefrontModel()

  // MARK: - The seven caches

  /// The accepted catalog, indexed. Cleared by `didAcceptCatalog()`.
  var catalogIndex: MemoObservationCatalogIndexCache?

  /// One browse screen's worth of search funnel.
  ///
  /// Cleared by a search-query write that changes the normalization, a category
  /// write, a stock-filter write, a sort-mode write, a catalog acceptance, and a
  /// search-index acceptance.
  var searchPipeline: MemoObservationSearchPipelineCache?

  /// What the list has materialized. Cleared whenever ``searchPipeline`` is,
  /// and by a row-window write.
  var window: MemoObservationWindowCache?

  /// One product's whole pricing ladder, as a single cell.
  ///
  /// Cleared per product by anything that moves that product's pricing inputs,
  /// and wholesale by anything that moves an input every product's ladder reads
  ///, the shopper, the coupon, the shipping address, and the shipping method.
  var pricing: [ProductID: Int] = [:]

  /// Everything one product's row renders.
  ///
  /// Cleared per product alongside ``pricing``, and also by the inputs a
  /// row reads but a price does not: the favorite flag and the live availability.
  var rows: [ProductID: ProductRow] = [:]

  /// The cart's expensive half. Cleared by any cart, coupon, or shipping write,
  /// by an accepted quote, and by a pricing change for a product in the cart.
  var cart: MemoObservationCartCache?

  // MARK: - The asynchronous cells

  /// The catalog, at the root of the browse half of the workload.
  var catalogCell = MemoObservationAsyncCell<CatalogSnapshot>(value: .empty)

  /// The signed-in shopper's account.
  ///
  /// Rests at `nil` rather than at a fabricated guest, exactly as the Cog port
  /// does: a pricing policy that reads a tier must be able to tell "not loaded"
  /// from "guest".
  var accountCell = MemoObservationAsyncCell<Shopper?>(value: nil)

  /// The inverted search index over the accepted catalog.
  var searchIndexCell = MemoObservationAsyncCell<StorefrontKernels.SearchIndex>(value: .empty)

  /// Suggestions for the query the shopper is typing.
  var suggestionsCell = MemoObservationAsyncCell<[String]>(value: [])

  /// Personalized recommendations, scored over the whole catalog.
  var recommendationsCell = MemoObservationAsyncCell<[ProductID]>(value: [])

  /// The shipping quote for the settled cart.
  var shippingQuoteCell = MemoObservationAsyncCell<ShippingQuote>(value: .pending)

  /// The tax quote for the settled cart.
  var taxQuoteCell = MemoObservationAsyncCell<TaxQuote>(value: .pending)

  /// Live inventory, per product.
  var inventoryCells: [ProductID: MemoObservationAsyncCell<InventoryReading>] = [:]

  /// The personalized offer, per product.
  var offerCells: [ProductID: MemoObservationAsyncCell<PersonalizedOffer>] = [:]

  /// The detail payload, per product.
  var detailCells: [ProductID: MemoObservationAsyncCell<ProductDetail>] = [:]

  /// The generation of recommendation demand a caller is holding a handle for.
  ///
  /// One at a time: a second demand resolves the first as superseded, which is
  /// what makes replacement a definite signal.
  var pendingRecommendationRefresh: MemoObservationRefreshCell?

  // MARK: - Bookkeeping

  /// Which observers owe a run at the next settlement.
  ///
  /// Five plain flags rather than a graph. Nothing computes them: each is set by
  /// name inside a hand-written invalidation method, and cleared when its
  /// observer runs.
  var browseDirty = false

  /// Whether the search observer owes a run.
  var searchDirty = false

  /// Whether the cart observer owes a run.
  var cartDirty = false

  /// Whether the detail observer owes a run.
  var detailDirty = false

  /// When each product was last demanded by a held observer.
  ///
  /// The only thing the time-to-live sweep consults. Stamped in
  /// `refreshDemand()`, which is the one place that knows what the held screens
  /// currently want.
  var productLastDemandedAt: [ProductID: Duration] = [:]

  /// Whether a caller established a durable demand for the ranked list.
  ///
  /// Set by ``demandRankedProductIDs()`` and never cleared, because the demand
  /// it represents is durable by contract: the footprint cut weighs the search
  /// funnel that read leaves materialized.
  var funnelIsDemanded = false

  /// Whether a verb's body is running, so its writes render once at its close.
  var isMutating = false

  /// The barrier armed by ``settlingOneAsyncResult(_:)``, if any.
  ///
  /// Fired by the asynchronous epilogue on both the publish and the discard
  /// branch, exactly once, and cleared as it fires.
  var armedCompletionSignal: StorefrontCompletionSignal?

  /// Creates an empty runtime around one session's configuration.
  ///
  /// Private because a Storefront session's initial state must be the one
  /// ``make(profile:service:initialWindow:holds:sink:grace:)`` installs: the
  /// starting row window is written and the observers registered before anything
  /// observes, so no held observer sees the pre-initial world on its way past.
  ///
  /// - Parameters:
  ///   - profile: The world's size.
  ///   - service: The request boundary to talk to.
  ///   - holds: Which durable observers to register.
  ///   - sink: Where those observers deposit what they read.
  ///   - grace: How long an undemanded per-product entry may survive.
  private init(
    profile: StorefrontProfile,
    service: StorefrontService,
    holds: StorefrontHolds,
    sink: StorefrontSink,
    grace: Duration
  ) {
    self.profile = profile
    self.service = service
    self.holds = holds
    self.sink = sink
    self.grace = grace
  }

  // MARK: - Construction

  /// Builds a fresh, isolated runtime whose initial state has already settled.
  ///
  /// The starting row window is written and the held observers registered here,
  /// before anything observes, so the bootstrap phase's browse-run count is a
  /// claim about registration rather than about a race. Each held observer runs
  /// exactly once in this call, and the demand pass that follows starts exactly
  /// the requests those observers imply, the account, the catalog, and the
  /// search index over the empty catalog the browse funnel just asked about.
  ///
  /// - Parameters:
  ///   - profile: The world's size.
  ///   - service: The request boundary to install.
  ///   - initialWindow: The row window the list starts at.
  ///   - holds: Which durable observers to register.
  ///   - sink: Where those observers deposit what they read.
  ///   - grace: How long an undemanded per-product entry may survive.
  /// - Returns: A live runtime whose initial state has settled.
  public static func make(
    profile: StorefrontProfile,
    service: StorefrontService,
    initialWindow: RowWindow,
    holds: StorefrontHolds,
    sink: StorefrontSink,
    grace: Duration
  ) -> MemoObservationStorefrontRuntime {
    let runtime = MemoObservationStorefrontRuntime(
      profile: profile,
      service: service,
      holds: holds,
      sink: sink,
      grace: grace
    )
    runtime.model.rowWindow = initialWindow
    runtime.browseDirty = true
    runtime.searchDirty = true
    runtime.cartDirty = true
    runtime.detailDirty = true
    if holds.contains(.account) {
      // The account observer's registration run, against the resting
      // signed-out value. An observer that only ran on change would leave the
      // signed-out world unwritten, and the account-run checkpoint counts this
      // one and the accepted response's as two.
      sink.recordAccount()
    }
    runtime.settle()
    return runtime
  }

  // MARK: - Settlement

  /// Applies one user action and settles once.
  ///
  /// - Parameter body: The writes and the invalidation they imply. Reads inside
  ///   see the writes made before them, because they are plain properties.
  func mutate(_ body: () -> Void) {
    guard !isMutating else {
      // A nested verb settles with its caller rather than on its own, so a
      // composite action is still one settlement.
      body()
      return
    }
    isMutating = true
    body()
    isMutating = false
    settle()
  }

  /// Renders every observer that owes a run, then starts every request the held
  /// screens now need.
  ///
  /// Rendering first is deliberate: a request identity is computed from settled
  /// values, the suggestion query, the discounted subtotal, the demanded row
  /// set, so the caches those identities are read out of must be current
  /// before the demand pass reads them. Starting a request changes no value, so
  /// nothing rendered here goes stale by the time the pass finishes.
  func settle() {
    render()
    refreshDemand()
  }

  // MARK: - Domain operations

  /// Records the account response the runtime accepted, or signs out.
  ///
  /// - Parameter shopper: The signed-in shopper, or `nil`.
  public func signIn(as shopper: Shopper?) {
    guard shopper != model.signedInShopper else { return }
    mutate {
      model.signedInShopper = shopper
      didWriteShopper()
    }
  }

  /// Records the rows the list has materialized.
  ///
  /// - Parameter window: The new window.
  public func scrollRows(to window: RowWindow) {
    guard window != model.rowWindow else { return }
    mutate {
      model.rowWindow = window
      didWriteRowWindow()
    }
  }

  /// Replaces the search field's contents.
  ///
  /// Two gates, not one. The outer gate is the ordinary "did the value change"
  /// every setter here has. The inner one is the gate that matters: a keystroke
  /// whose *normalization* matches what the funnel was last built for costs a
  /// property write and nothing else, no re-tokenizing, no re-intersecting, no
  /// re-ranking, and no new suggestion generation. That is one hand-written
  /// line standing in for the equality gate the Cog port gets from declaring the
  /// normalized query as a value.
  ///
  /// - Parameter text: The field's new contents.
  public func typeSearchQuery(_ text: String) {
    guard text != model.searchQuery else { return }
    let normalized = StorefrontKernels.normalize(text)
    mutate {
      model.searchQuery = text
      guard normalized != searchPipeline?.normalizedQuery else { return }
      didWriteSearchQuery()
    }
  }

  /// Applies the browse screen's filters and resets the window, in one settle.
  ///
  /// Four sources in one `mutate`, and the window's new offset is zero over the
  /// transaction's own staged length. Performing this as separate writes would
  /// render two or three screens no shopper asked for.
  ///
  /// - Parameters:
  ///   - category: The category to filter to, or `nil` for all.
  ///   - sortMode: How to order results.
  ///   - inStockOnly: Whether to hide out-of-stock products.
  public func applyBrowseFilters(category: CategoryID?, sortMode: SortMode, inStockOnly: Bool) {
    mutate {
      if category != model.selectedCategory {
        model.selectedCategory = category
        didWriteCategory()
      }
      if sortMode != model.sortMode {
        model.sortMode = sortMode
        didWriteSortMode()
      }
      if inStockOnly != model.inStockOnly {
        model.inStockOnly = inStockOnly
        didWriteInStockOnly()
      }
      let reset = RowWindow(offset: 0, length: model.rowWindow.length)
      if reset != model.rowWindow {
        model.rowWindow = reset
        didWriteRowWindow()
      }
    }
  }

  /// Selects one category without disturbing the rest of the filter bar.
  ///
  /// - Parameter category: The category, or `nil` for all.
  public func selectCategory(_ category: CategoryID?) {
    guard category != model.selectedCategory else { return }
    mutate {
      model.selectedCategory = category
      didWriteCategory()
    }
  }

  /// Chooses how results are ordered.
  ///
  /// - Parameter mode: The sort mode.
  public func selectSortMode(_ mode: SortMode) {
    guard mode != model.sortMode else { return }
    mutate {
      model.sortMode = mode
      didWriteSortMode()
    }
  }

  /// Shows or hides out-of-stock products.
  ///
  /// - Parameter isOn: Whether to hide them.
  public func setInStockOnly(_ isOn: Bool) {
    guard isOn != model.inStockOnly else { return }
    mutate {
      model.inStockOnly = isOn
      didWriteInStockOnly()
    }
  }

  /// Toggles one product's favorite flag.
  ///
  /// No equality gate, and it would be wrong to add one: the new value is
  /// computed from the staged old one, so two toggles in one settlement cancel
  /// rather than both setting `true`.
  ///
  /// - Parameter id: Which product.
  public func toggleFavorite(_ id: ProductID) {
    mutate {
      model.favorites[id] = !(model.favorites[id] ?? false)
      // The favorite flag reaches a badge and nothing else, so the ladder is
      // left alone.
      didChangeProduct(id, pricingAffected: false)
    }
  }

  /// Opens a product's detail screen and records that it was viewed.
  ///
  /// Selection and recency rank move together. A split would render the detail
  /// screen against a stale rank and would run the recency-dependent part of
  /// the ladder twice for one navigation.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - rank: The recency rank to record; larger is more recent.
  public func openProduct(_ id: ProductID, rank: Int) {
    mutate {
      if model.selectedProduct != id {
        model.selectedProduct = id
        didWriteSelectedProduct()
      }
      if model.recentlyViewedRanks[id] != rank {
        model.recentlyViewedRanks[id] = rank
        // The recency nudge is a pricing policy, so the ladder is affected.
        didChangeProduct(id, pricingAffected: true)
      }
    }
  }

  /// Returns to the browse screen.
  public func closeProduct() {
    guard model.selectedProduct != nil else { return }
    mutate {
      model.selectedProduct = nil
      didWriteSelectedProduct()
    }
  }

  /// Selects a variant of one product.
  ///
  /// - Parameters:
  ///   - variantIndex: Which variant. Clamped exactly where
  ///     ``StorefrontPricing`` clamps and nowhere else; the availability
  ///     computation is deliberately unclamped.
  ///   - id: Which product.
  public func selectVariant(_ variantIndex: Int, for id: ProductID) {
    guard model.selectedVariants[id] != variantIndex else { return }
    mutate {
      model.selectedVariants[id] = variantIndex
      didChangeProduct(id, pricingAffected: true)
    }
  }

  /// Adds a product to the cart, or increases its quantity.
  ///
  /// Membership and quantity move together, conditional on the staged quantity.
  /// Writing them separately would let a settled state observe a product in the
  /// cart with quantity zero, and would start a shipping and tax quote
  /// generation for that impossible subtotal.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - quantity: How many to add.
  public func addToCart(_ id: ProductID, quantity: Int) {
    mutate {
      let existing = model.cartQuantities[id] ?? 0
      model.cartQuantities[id] = existing + quantity
      if existing == 0 { model.cartContents.append(id) }
      didWriteCart(affecting: id)
    }
  }

  /// Sets one line's quantity, removing the line at zero.
  ///
  /// - Parameters:
  ///   - quantity: The new quantity; zero or less removes the line.
  ///   - id: Which product.
  public func setCartQuantity(_ quantity: Int, for id: ProductID) {
    let clamped = max(0, quantity)
    let isMember = model.cartContents.contains(id)
    guard clamped != model.cartQuantities[id] ?? 0 || isMember == (clamped <= 0) else { return }
    mutate {
      model.cartQuantities[id] = clamped
      if quantity <= 0 {
        model.cartContents.removeAll { $0 == id }
      } else if !isMember {
        model.cartContents.append(id)
      }
      didWriteCart(affecting: id)
    }
  }

  /// Applies or clears a coupon.
  ///
  /// - Parameter coupon: The typed coupon, or `nil` to clear it.
  public func applyCoupon(_ coupon: CouponCode?) {
    guard coupon != model.coupon else { return }
    mutate {
      model.coupon = coupon
      didWriteCoupon()
    }
  }

  /// Chooses where the order ships.
  ///
  /// - Parameter address: The address.
  public func selectShippingAddress(_ address: ShippingAddress) {
    guard address != model.shippingAddress else { return }
    mutate {
      model.shippingAddress = address
      didWriteShippingAddress()
    }
  }

  /// Chooses how the order ships.
  ///
  /// - Parameter method: The method.
  public func selectShippingMethod(_ method: ShippingMethod) {
    guard method != model.shippingMethod else { return }
    mutate {
      model.shippingMethod = method
      didWriteShippingMethod()
    }
  }

  /// Publishes one inventory burst.
  ///
  /// Every touched product's generation advances in one settlement, and that
  /// settlement invalidates **nothing**. This is the port's sharpest behavior
  /// and it is worth being explicit about: a generation is the key the next
  /// inventory request is asked under, not a value a row renders. Every row
  /// keeps showing the last accepted reading, so no cache is stale and no
  /// observer owes a run, while the demand pass at the close notices that the
  /// demanded rows' inventory identities moved and asks for those, and only
  /// those. The offscreen half is not in the demanded set, so it starts nothing
  /// and costs nothing until something wants those rows again.
  ///
  /// - Parameters:
  ///   - ids: The products the feed touched.
  ///   - generation: The generation to advance them to.
  public func publishInventoryBurst(_ ids: [ProductID], generation: Int) {
    mutate {
      for id in ids where model.inventoryGenerations[id] ?? 0 != generation {
        model.inventoryGenerations[id] = generation
      }
    }
  }

  // MARK: - Asynchronous demand

  /// Re-demands the catalog.
  ///
  /// Not used by the trace; a SwiftUI comparison app exposes it as
  /// pull-to-refresh. Forces the next demand pass to ask again even though the
  /// request identity has not changed.
  public func refreshCatalog() {
    catalogCell.needsRefetch = true
    settle()
  }

  /// Re-demands one product's inventory.
  ///
  /// - Parameter id: Which product.
  public func refreshInventory(for id: ProductID) {
    guard inventoryCells[id] != nil else { return }
    inventoryCells[id]?.needsRefetch = true
    settle()
  }

  /// Demands fresh recommendations and hands back that exact demand's handle.
  ///
  /// - Returns: A handle bound to this generation, never to a later one.
  @discardableResult
  public func refreshRecommendations() -> MemoObservationRefresh {
    let cell = MemoObservationRefreshCell()
    // Replacement is what makes the previous handle a definite signal: it
    // resolves at this moment, not when its task eventually finishes.
    pendingRecommendationRefresh?.resolve(.superseded)
    pendingRecommendationRefresh = cell
    // An explicit demand asks again even though the request identity has not
    // moved, which is the whole point of a refresh.
    recommendationsCell.needsRefetch = true
    demandRecommendations()
    if recommendationsCell.pendingKey == nil {
      // With no signed-in shopper, return the resting value. Do not leave a
      // demand handle that no request can resolve.
      pendingRecommendationRefresh = nil
      cell.resolve(.success(recommendationsCell.value))
    }
    return MemoObservationRefresh(cell: cell)
  }

  // MARK: - Settled inspection

  /// The price this runtime currently reports for one product.
  ///
  /// Untracked: it answers from the pricing cache when there is an entry and
  /// computes a throwaway ladder when there is not. It never *writes* the
  /// cache, never stamps a demand, and never starts a request, because the
  /// teardown phase's release proof would be invalidated by any of the three.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  public func peekEffectivePrice(of id: ProductID) -> Int {
    pricing[id] ?? computeEffectivePrice(of: id)
  }

  /// The promotion plan this runtime currently reports.
  ///
  /// Untracked, for the same reason as ``peekEffectivePrice(of:)``.
  ///
  /// - Returns: The settled promotion plan.
  public func peekPromotionPlan() -> PromotionPlan {
    cart?.promotionPlan ?? computeCartCache().promotionPlan
  }

  /// Establishes a durable demand for the ranked product list and returns it.
  ///
  /// The opposite of the two peeks: this read builds the funnel cache and marks
  /// it durably demanded, so the index, candidates, eligibility, scores, and
  /// ranking stay materialized afterwards and can be weighed.
  ///
  /// - Returns: The ranked product identifiers, in rank order.
  @discardableResult
  public func demandRankedProductIDs() -> [ProductID] {
    funnelIsDemanded = true
    let ranked = searchPipelineCache().rankedIDs
    refreshDemand()
    return ranked
  }

  // MARK: - Settlement barriers

  /// Runs `body` and returns once exactly one asynchronous result has reached
  /// this runtime's publish decision.
  ///
  /// The barrier is armed before `body` runs, because a scripted release can
  /// resume and publish before the caller would otherwise be suspended. It fires
  /// for an accepted result and for a refused one alike: a decision to discard a
  /// stale result is exactly as much of a decision as a decision to publish one.
  ///
  /// - Parameter body: The release that will produce the result.
  public func settlingOneAsyncResult(_ body: () async throws -> Void) async throws {
    let signal = StorefrontCompletionSignal()
    armedCompletionSignal = signal
    try await body()
    try await signal.wait()
  }

  /// Advances this runtime's injected clock past its grace period and sweeps.
  ///
  /// Synchronous and total: the sweep runs to completion before this returns, so
  /// a phase can establish that the runtime made up its mind without polling,
  /// including when it decides to keep everything, which is a completed decision
  /// too.
  ///
  /// - Parameter duration: How far past grace to advance.
  public func settlingLifetimeRelease(advancingBy duration: Duration) async throws {
    clock.advance(by: duration)
    sweepReleasableProducts()
    settle()
  }

  nonisolated deinit {}
}
