internal import StateGraph
public import StorefrontWorkload

/// The swift-state-graph implementation of the Storefront workload.
///
/// The fourth of the four runtimes the Storefront macrobenchmark compares, and
/// the only one that ports the workload onto somebody else's library. It runs
/// the identical eleven-phase trace from `StorefrontWorkload`, against the
/// identical fixtures, the identical scripted request boundary, and the
/// identical shadow model as the Cog reference — which is what makes its
/// numbers comparable rather than merely adjacent.
///
/// Everything that swift-state-graph 0.28.0 provides is used as it is
/// provided: `Stored` for sources, `Computed` for derived values,
/// `withGraphTransaction` for the write boundary, and the library's own
/// pull-based invalidation for everything in between. The derivation graph in
/// `StorefrontStateGraphNodes.swift` is the same nodes, the same dependencies,
/// and the same kernels with the same arguments as
/// `swift/Benchmarks/Macro/Storefront/Workload/Sources/CogStorefront/`.
///
/// ## Three disclosed deviations
///
/// A port that quietly did less than the reference would report a flattering
/// number, so the three places this one differs are stated here, in
/// `README.md`, and in `docs/swift/impl/perf.md`.
///
/// 1. **Rendering is explicit.** swift-state-graph's derivation and
///    invalidation are the library's and are what is measured. Its observer
///    *scheduling* is not used, because `withGraphTracking` re-applies on the
///    next event loop — measured, probe `d2` in `API-NOTES.md` — and this trace
///    reads a settled value on the next line. All three non-Cog ports therefore
///    render explicitly at the close of a transaction; only Cog's reactions are
///    the library's own. That is a scheduling mismatch, not a defect.
/// 2. **The asynchronous layer is the port's.** 0.28.0 has no async node
///    primitive, so the request plans, generations, acceptance rule, and demand
///    handles in `StorefrontStateGraphAsync.swift` are hand-written and their
///    cost is inside every number this runtime reports.
/// 3. **The keyed collections and the release policy are the port's.** 0.28.0
///    has no keyed-node facility and no lifetime model, so both are dictionaries
///    and a sweep this file owns.
///
/// ## Identity and ownership
///
/// One instance per session, created by
/// ``make(profile:service:initialWindow:holds:sink:grace:)`` and retained by the
/// driver. It owns the node storage, every request task, the slot table, and the
/// injected clock; the driver owns the script, the sink, and the shadow world.
///
/// ## Isolation
///
/// MainActor-confined. Every verb writes on the MainActor, every render settles
/// on it, and every publish-or-discard decision is made on it. Only the body of
/// a request runs elsewhere, through `@concurrent`, exactly as Cog's
/// `.run { @concurrent … }` does.
///
/// ## Turn and settlement ordering
///
/// Each verb is one `withGraphTransaction` followed by one settlement, and the
/// order inside that settlement is load-bearing. Asynchronous selection runs
/// *first*, because a plan that short-circuits publishes its resting value
/// synchronously and the render must see it; the render runs once, afterwards,
/// and is the point at which derived values are read and deposited. Derived
/// values are never read inside the transaction: `transactionValue()`
/// re-evaluates a rule from staged values on every read and never updates the
/// cache (`StateGraph.swift:264-286`, probe `b4`), so three in-transaction
/// reads cost three full evaluations and a fourth afterwards.
///
/// The settlement barrier is the read itself. `withGraphTransaction` returns
/// with every staged value committed and every dependent flagged, and
/// `Computed.wrappedValue` then settles its whole upstream funnel synchronously
/// on the reading thread. That is why a verb can return settled and the trace
/// can read the sink on the next line.
///
/// ## Observation
///
/// A held observer deposits into the shared ``StorefrontSink`` and counts its
/// own run. Because rendering is explicit, this runtime decides whether a run
/// happened by comparing what it just read with what it last deposited — output
/// comparison, which ``StorefrontRuntimeSemantics`` requires be declared rather
/// than assumed. Its equality gates are the library's: `Stored` is gated by
/// `{ $0 != $1 }` and `Computed` by `isEqual: { $0 == $1 }`, so an equal write
/// invalidates nothing and the roots this compares are usually still the cached
/// values. The cost of that re-read is inside every measured number.
///
/// ## Cancellation and races
///
/// A completed-but-superseded result is refused by *generation*, captured
/// synchronously at selection time, and never by task cancellation: the request
/// script leaves cancelled requests suspended by default precisely so a port
/// cannot pass the stale-result checkpoint by accident. This runtime does not
/// cancel superseded tasks at all — it lets them complete and refuses them,
/// which is the stronger proof.
///
/// `nonisolated deinit` per the repository convention: under
/// `.defaultIsolation(MainActor.self)` a synthesized deinit would ask the
/// concurrency runtime which executor it is on for every deallocation.
@MainActor
public final class StateGraphStorefrontRuntime: StorefrontRuntime {
  /// The per-generation demand handle this runtime hands back.
  public typealias Refresh = StateGraphStorefrontRefresh

  /// The swift-state-graph release this port is written and measured against.
  ///
  /// Duplicated from the manifest's `exact:` pin on purpose: a reader of this
  /// source should not have to open a manifest to learn which library version
  /// the surrounding code's assumptions were confirmed on, and the version is
  /// part of every result this runtime contributes.
  public static let stateGraphVersion = "0.28.0"

  /// What this runtime is called in a benchmark name, and what it guarantees.
  ///
  /// Every value is justified in `README.md` and repeated in
  /// `docs/swift/impl/perf.md`, as ``StorefrontRuntimeSemantics``
  /// requires. In short: one transaction plus one explicit render is one
  /// settlement; `Stored`'s equality gate means an equal write invalidates
  /// nothing, so the render finds unchanged roots and deposits nothing; an
  /// invalidation confined to offscreen inputs reaches no root the render reads
  /// and no slot the port polls, so it neither renders nor asks the service for
  /// anything; the account observer runs at registration against the resting
  /// signed-out value and again when the response lands; the port's own release
  /// sweep frees per-product derived and asynchronous state past grace; and a
  /// completion is accepted only when it names the generation the slot is on.
  public static let descriptor = StorefrontRuntimeDescriptor(
    slug: "state-graph",
    displayName: "swift-state-graph",
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

  /// How many rounds of asynchronous selection one settlement may take.
  ///
  /// A short-circuiting plan publishes its resting value synchronously, which
  /// can change a derived value another plan reads, so selection is a small
  /// fixed point rather than a single pass. Two rounds is the most the workload
  /// needs; the limit is a backstop that traps rather than a budget, because a
  /// runtime whose selection never converged would spin instead of failing.
  private static let selectionRoundLimit = 8

  /// The world's size. Fixed for the session.
  private let profile: StorefrontProfile

  /// The installed request boundary.
  private let service: StorefrontService

  /// Which durable observers this session registers.
  private let holds: StorefrontHolds

  /// Where those observers deposit what they read.
  private let sink: StorefrontSink

  /// How long a per-product value with no demand may survive before release.
  private let grace: Duration

  /// Whether this profile's pricing ladder reads the personalized offer.
  ///
  /// Derived from the profile rather than observed, exactly as the trace
  /// derives it: a cart line demands an offer only when the ladder prefix
  /// reaches ``StorefrontPricing/Policy/personalizedOffer``, because a cart line
  /// reads the effective price but not the badges. A row on screen always
  /// demands one, because its badges do.
  private let pricingReadsOffers: Bool

  /// Every node in the graph.
  private let nodes: StorefrontStateGraphNodes

  /// Generation, plan, and demand stamp for each asynchronous identity.
  private var slots: [StorefrontStateGraphAsyncKey: StorefrontStateGraphSlot] = [:]

  /// When each materialized product was last demanded.
  ///
  /// The port's own lifetime bookkeeping, on the port's own injected clock.
  private var productDemandStamps: [ProductID: Duration] = [:]

  /// Unresolved recommendation demand handles, by the generation each names.
  private var recommendationRefreshes: [Int: StorefrontStateGraphRefreshPromise] = [:]

  /// The injected clock lifetime grace is measured on.
  ///
  /// A monotonic counter rather than a `Clock` conformance, because nothing
  /// sleeps on it: the trace advances it through
  /// ``settlingLifetimeRelease(advancingBy:)`` and the sweep is synchronous.
  private var clock: Duration = .zero

  /// The barrier armed for the next publish-or-discard decision, if any.
  ///
  /// Armed before the release that produces the result, because a scripted
  /// release can resume and publish before the caller would otherwise be
  /// suspended. Cleared as it is fired so that a second decision in the same
  /// window cannot fire it twice.
  private var armedCompletionSignal: StorefrontCompletionSignal?

  /// What the browse observer last deposited.
  private var lastBrowsePayload: BrowsePayload?

  /// What the search observer last deposited.
  private var lastSuggestions: [String]?

  /// What the cart observer last deposited.
  private var lastCartPayload: CartPayload?

  /// What the detail observer last deposited.
  private var lastDetailPayload: DetailPayload?

  /// What one browse run saw.
  ///
  /// Compared against the previous run's, because rendering is explicit: this
  /// runtime has to decide for itself whether an observer ran, and the honest
  /// way to decide is to look at what it would have deposited.
  private nonisolated struct BrowsePayload: Equatable {
    /// The products on screen, in list order.
    var visible: [ProductID]
    /// The products whose rows were read, including the prefetch margin.
    var demanded: [ProductID]
    /// The digest of every visible row's rendered content.
    var checksum: Int
  }

  /// What one cart run saw.
  private nonisolated struct CartPayload: Equatable {
    /// The cart's money.
    var total: OrderTotal
    /// Whether checkout was ready.
    var readiness: CheckoutReadiness
  }

  /// What one detail run saw.
  private nonisolated struct DetailPayload: Equatable {
    /// The open product's review count, or zero.
    var reviewCount: Int
    /// The accepted recommendations.
    var recommendations: [ProductID]
  }

  /// Creates a runtime around a fresh graph.
  ///
  /// Private because a Storefront session's graph must be the one
  /// ``make(profile:service:initialWindow:holds:sink:grace:)`` assembled: the
  /// starting row window is written inside the node storage's initializer and
  /// the observers register inside `make`, so a runtime assembled any other way
  /// would let a held observer see the pre-initial world on its way past.
  private init(
    profile: StorefrontProfile,
    service: StorefrontService,
    initialWindow: RowWindow,
    holds: StorefrontHolds,
    sink: StorefrontSink,
    grace: Duration
  ) {
    self.profile = profile
    self.service = service
    self.holds = holds
    self.sink = sink
    self.grace = grace
    pricingReadsOffers = StorefrontPricing.ladder
      .prefix(profile.pricingPolicyCount)
      .contains(.personalizedOffer)
    nodes = StorefrontStateGraphNodes(
      profile: profile,
      service: service,
      initialWindow: initialWindow
    )
  }

  // MARK: - Construction

  /// Builds a fresh, isolated runtime whose initial state has already settled.
  ///
  /// The service is injected, the starting row window is written before
  /// anything observes, the requested observers register here, and the first
  /// settlement runs before this returns — so the bootstrap phase's browse-run
  /// count is a claim about registration rather than about a race, and its
  /// three root requests have already been scheduled by the time the driver
  /// asks.
  ///
  /// - Parameters:
  ///   - profile: The world's size.
  ///   - service: The installed request boundary.
  ///   - initialWindow: The row window the list starts at.
  ///   - holds: Which durable observers to register.
  ///   - sink: Where those observers deposit what they read.
  ///   - grace: How long an undemanded per-product value may survive.
  /// - Returns: A live runtime whose initial state has settled.
  public static func make(
    profile: StorefrontProfile,
    service: StorefrontService,
    initialWindow: RowWindow,
    holds: StorefrontHolds,
    sink: StorefrontSink,
    grace: Duration
  ) -> StateGraphStorefrontRuntime {
    let runtime = StateGraphStorefrontRuntime(
      profile: profile,
      service: service,
      initialWindow: initialWindow,
      holds: holds,
      sink: sink,
      grace: grace
    )
    runtime.registerObservers()
    return runtime
  }

  /// Runs each held observer once and settles the graph.
  ///
  /// The account observer is the one that runs *here* rather than in the
  /// render: it runs at registration against the resting signed-out value and
  /// again when the response lands, and never in between, exactly as Cog's
  /// `watch(storefrontAccountCog, initial: .run)` does. Two runs through sign-in
  /// is what ``StorefrontRuntimeSemantics/accountRunsThroughSignIn`` declares,
  /// and an observer that only fired on change would leave the signed-out world
  /// unwritten.
  private func registerObservers() {
    if holds.contains(.account) { runAccountObserver(nodes.account.wrappedValue) }
    settle()
  }

  // MARK: - Domain operations

  /// Applies one user action as one transaction and one settlement.
  ///
  /// Every verb goes through here, and it is the whole of this runtime's
  /// write boundary. `withGraphTransaction` is used on **correctness** grounds
  /// and not for run counting: it buys atomic visibility, native
  /// read-your-own-staged-writes, one notification wave, and rollback. It does
  /// *not* coalesce recomputation — `Computed` is pull-based, so N writes
  /// followed by one read produce one recomputation with or without it (probes
  /// `b1` and `b2`). Reading once is what produces one settled render; the
  /// transaction is what stops a multi-source verb from rendering a screen no
  /// shopper asked for on the way.
  ///
  /// - Parameter body: The staged writes. Reads inside it see this
  ///   transaction's own staged values.
  private func perform(_ body: () -> Void) {
    withGraphTransaction { body() }
    settle()
  }

  /// Records the account response the runtime accepted, or signs out.
  ///
  /// - Parameter shopper: The signed-in shopper, or `nil`.
  public func signIn(as shopper: Shopper?) {
    perform { nodes.signedInShopper.wrappedValue = shopper }
  }

  /// Records the rows the list has materialized.
  ///
  /// - Parameter window: The new window.
  public func scrollRows(to window: RowWindow) {
    perform { nodes.rowWindow.wrappedValue = window }
  }

  /// Replaces the search field's contents.
  ///
  /// - Parameter text: The field's new contents.
  public func typeSearchQuery(_ text: String) {
    perform { nodes.searchQuery.wrappedValue = text }
  }

  /// Applies the browse screen's filters and resets the window, in one settle.
  ///
  /// Four sources move together and the window's new value is read from this
  /// transaction's own staged state, which `Stored`'s getter provides natively
  /// inside a transaction (`Stored.swift:105-134`).
  ///
  /// - Parameters:
  ///   - category: The category to filter to, or `nil` for all.
  ///   - sortMode: How to order results.
  ///   - inStockOnly: Whether to hide out-of-stock products.
  public func applyBrowseFilters(category: CategoryID?, sortMode: SortMode, inStockOnly: Bool) {
    perform {
      nodes.selectedCategory.wrappedValue = category
      nodes.sortMode.wrappedValue = sortMode
      nodes.inStockOnly.wrappedValue = inStockOnly
      nodes.rowWindow.wrappedValue = RowWindow(
        offset: 0,
        length: nodes.rowWindow.wrappedValue.length
      )
    }
  }

  /// Selects one category without disturbing the rest of the filter bar.
  ///
  /// - Parameter category: The category, or `nil` for all.
  public func selectCategory(_ category: CategoryID?) {
    perform { nodes.selectedCategory.wrappedValue = category }
  }

  /// Chooses how results are ordered.
  ///
  /// - Parameter mode: The sort mode.
  public func selectSortMode(_ mode: SortMode) {
    perform { nodes.sortMode.wrappedValue = mode }
  }

  /// Shows or hides out-of-stock products.
  ///
  /// - Parameter isOn: Whether to hide them.
  public func setInStockOnly(_ isOn: Bool) {
    perform { nodes.inStockOnly.wrappedValue = isOn }
  }

  /// Toggles one product's favorite flag.
  ///
  /// Reads its own staged value, so two toggles in one settle would cancel
  /// rather than both setting `true`.
  ///
  /// - Parameter id: Which product.
  public func toggleFavorite(_ id: ProductID) {
    perform {
      let node = nodes.favorite(id)
      node.wrappedValue = !node.wrappedValue
    }
  }

  /// Opens a product's detail screen and records that it was viewed.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - rank: The recency rank to record; larger is more recent.
  public func openProduct(_ id: ProductID, rank: Int) {
    perform {
      nodes.selectedProduct.wrappedValue = id
      nodes.recentlyViewedRank(id).wrappedValue = rank
    }
  }

  /// Returns to the browse screen.
  public func closeProduct() {
    perform { nodes.selectedProduct.wrappedValue = nil }
  }

  /// Selects a variant of one product.
  ///
  /// - Parameters:
  ///   - variantIndex: Which variant.
  ///   - id: Which product.
  public func selectVariant(_ variantIndex: Int, for id: ProductID) {
    perform { nodes.selectedVariant(id).wrappedValue = variantIndex }
  }

  /// Adds a product to the cart, or increases its quantity.
  ///
  /// Membership and quantity are two sources and this is one action, so it is
  /// one transaction; the membership write is conditional on a staged read.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - quantity: How many to add.
  public func addToCart(_ id: ProductID, quantity: Int) {
    perform {
      let quantityNode = nodes.cartQuantity(id)
      let existing = quantityNode.wrappedValue
      quantityNode.wrappedValue = existing + quantity
      if existing == 0 {
        nodes.cartContents.wrappedValue = nodes.cartContents.wrappedValue + [id]
      }
    }
  }

  /// Sets one line's quantity, removing the line at zero.
  ///
  /// - Parameters:
  ///   - quantity: The new quantity; zero or less removes the line.
  ///   - id: Which product.
  public func setCartQuantity(_ quantity: Int, for id: ProductID) {
    perform {
      nodes.cartQuantity(id).wrappedValue = max(0, quantity)
      if quantity <= 0 {
        nodes.cartContents.wrappedValue = nodes.cartContents.wrappedValue.filter { $0 != id }
      } else if !nodes.cartContents.wrappedValue.contains(id) {
        nodes.cartContents.wrappedValue = nodes.cartContents.wrappedValue + [id]
      }
    }
  }

  /// Applies or clears a coupon.
  ///
  /// - Parameter coupon: The typed coupon, or `nil` to clear it.
  public func applyCoupon(_ coupon: CouponCode?) {
    perform { nodes.coupon.wrappedValue = coupon }
  }

  /// Chooses where the order ships.
  ///
  /// - Parameter address: The address.
  public func selectShippingAddress(_ address: ShippingAddress) {
    perform { nodes.shippingAddress.wrappedValue = address }
  }

  /// Chooses how the order ships.
  ///
  /// - Parameter method: The method.
  public func selectShippingMethod(_ method: ShippingMethod) {
    perform { nodes.shippingMethod.wrappedValue = method }
  }

  /// Publishes one inventory burst.
  ///
  /// Every touched product's generation advances in **one** transaction, which
  /// is what a warehouse feed looks like. Only the generation moves: the
  /// accepted readings are untouched, and they are what rows render — so a
  /// burst makes readings stale without making any row wrong, and the offscreen
  /// half reaches no root the render reads and no slot the port polls.
  ///
  /// - Parameters:
  ///   - ids: The products the feed touched.
  ///   - generation: The generation to advance them to.
  public func publishInventoryBurst(_ ids: [ProductID], generation: Int) {
    perform {
      for id in ids { nodes.inventoryGeneration(id).wrappedValue = generation }
    }
  }

  // MARK: - Asynchronous demand

  /// Demands a fresh catalog.
  public func refreshCatalog() {
    forceRefresh(.catalog)
  }

  /// Demands a fresh inventory reading for one product.
  ///
  /// - Parameter id: Which product.
  public func refreshInventory(for id: ProductID) {
    forceRefresh(.inventory(id))
  }

  /// Demands fresh recommendations and hands back that demand's handle.
  ///
  /// The handle is bound to the generation this call starts and never drifts to
  /// a later one: a replacing call advances the slot's generation and resolves
  /// this one as ``StorefrontRefreshOutcome/superseded`` at that moment, without
  /// a clock, a poll, or a timeout.
  ///
  /// - Returns: A handle bound to this generation.
  @discardableResult
  public func refreshRecommendations() -> StateGraphStorefrontRefresh {
    let promise = StorefrontStateGraphRefreshPromise()
    let generation = forceRefresh(.recommendations)
    recommendationRefreshes[generation] = promise
    if slots[.recommendations]?.plan == .resting {
      // Nothing to ask: no shopper is signed in, so the declaration's resting
      // value is the whole answer and the generation is complete already.
      resolveRecommendationRefresh(
        generation: generation,
        outcome: .success(nodes.recommendations.wrappedValue)
      )
    }
    return StateGraphStorefrontRefresh(promise: promise)
  }

  // MARK: - Settled inspection

  /// The price this runtime currently reports for one product.
  ///
  /// Untracked, and untracked for free: an edge is recorded only when the read
  /// happens inside another node's rule (`StateGraph.swift:442-451`), and this
  /// runtime registers no tracking scopes at all. It also does not stamp
  /// demand, so a checkpoint reading a price cannot keep that product's state
  /// alive past grace and invalidate the teardown phase's release proof.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  public func peekEffectivePrice(of id: ProductID) -> Int {
    nodes.effectivePrice(id).wrappedValue
  }

  /// The promotion plan this runtime currently reports.
  ///
  /// - Returns: The settled promotion plan.
  public func peekPromotionPlan() -> PromotionPlan {
    nodes.promotionPlan.wrappedValue
  }

  /// Establishes a durable demand for the ranked product list and returns it.
  ///
  /// The opposite of the two peeks: reading the ranking materializes the whole
  /// search funnel behind it — index, candidates, per-product eligibility and
  /// scores, ranking — and those caches stay in the graph afterwards, which is
  /// what the footprint cut weighs.
  ///
  /// - Returns: The ranked product identifiers, in rank order.
  @discardableResult
  public func demandRankedProductIDs() -> [ProductID] {
    nodes.rankedProductIDs.wrappedValue
  }

  // MARK: - Settlement barriers

  /// Runs `body` and returns once exactly one asynchronous result has reached
  /// this runtime's publish decision.
  ///
  /// The barrier is armed before `body` runs, because a scripted release can
  /// resume and publish before the caller would otherwise be suspended. It
  /// fires on both branches of the epilogue — for an accepted result and for a
  /// stale one this runtime refuses — because a decision to discard is exactly
  /// as much of a signal as a decision to publish, and the search phase's stale
  /// step is built on that.
  ///
  /// - Parameter body: The release that will produce the result.
  public func settlingOneAsyncResult(_ body: () async throws -> Void) async throws {
    let signal = StorefrontCompletionSignal()
    armedCompletionSignal = signal
    try await body()
    try await signal.wait()
  }

  /// Advances this runtime's injected clock past grace and releases what is no
  /// longer demanded.
  ///
  /// Synchronous, and returns after the decision rather than after a duration:
  /// the sweep runs, the released products' nodes and slots are dropped, and
  /// the graph settles again before this returns. It is `async` only because
  /// the protocol is, and it fires no barrier because there is nothing to wait
  /// for — a runtime whose release decision needed a scheduler could not
  /// satisfy this trace at all.
  ///
  /// - Parameter duration: How far past grace to advance.
  public func settlingLifetimeRelease(advancingBy duration: Duration) async throws {
    clock += duration
    sweepReleasableProducts()
    settle()
  }

  // MARK: - Settlement

  /// Converges asynchronous selection, then renders once.
  ///
  /// Selection first, because a plan that short-circuits publishes its resting
  /// value synchronously and the render must see it; a fixed point rather than
  /// one pass, because one resting publication can change a value another plan
  /// reads. The render is what deposits into the sink, and it happens exactly
  /// once per settlement — which is what
  /// ``StorefrontRuntimeSemantics/browseRunsPerContentChangingTurn`` claims.
  private func settle() {
    var rounds = 0
    while pollAsyncDemand() {
      rounds += 1
      guard rounds < Self.selectionRoundLimit else {
        fatalError(
          """
          The state-graph Storefront runtime's asynchronous selection did not converge after \
          \(Self.selectionRoundLimit) rounds. A plan that short-circuits publishes its resting \
          value synchronously, so a plan whose resting value changes another plan is a demand \
          loop in the port rather than a slow settlement.
          """
        )
      }
    }
    render()
  }

  /// Selects every demanded asynchronous slot, starting or resting each one.
  ///
  /// Demand is structural rather than observed, and this method is the one
  /// place that states it: a row on screen or in the prefetch margin demands
  /// inventory and an offer because its badges read both; a cart line demands
  /// inventory because it reads availability, and an offer only when the
  /// profile's pricing ladder reaches the personalized-offer stage; an open
  /// product demands its detail payload and the recommendation shelf. That is
  /// the same demand the derivation graph expresses, restated here because the
  /// port owns the asynchronous layer and something has to decide which slots
  /// to poll. An undemanded slot is never polled, which is why an inventory
  /// burst covering offscreen products asks the service for nothing.
  ///
  /// - Returns: Whether any slot published a resting value synchronously, in
  ///   which case selection has to run again before the render.
  private func pollAsyncDemand() -> Bool {
    var published = false

    if holds.contains(.account) { published = demand(.account) || published }
    if holdsAnyScreen { published = demand(.catalog) || published }
    if holds.contains(.browse) { published = demand(.searchIndex) || published }
    if holds.contains(.search) { published = demand(.suggestions) || published }
    if holds.contains(.cart) {
      published = demand(.shippingQuote) || published
      published = demand(.taxQuote) || published
    }

    let rows = holds.contains(.browse) ? nodes.prefetchProductIDs.wrappedValue : []
    let cartIDs = holds.contains(.cart) ? nodes.cartLineIDs.wrappedValue : []
    let openProduct = holds.contains(.detail) ? nodes.selectedProduct.wrappedValue : nil

    if openProduct != nil { published = demand(.recommendations) || published }

    var seenInventory: Set<ProductID> = []
    for id in rows + cartIDs where seenInventory.insert(id).inserted {
      productDemandStamps[id] = clock
      published = demand(.inventory(id)) || published
    }

    var seenOffer: Set<ProductID> = []
    let offerIDs = pricingReadsOffers ? rows + cartIDs : rows
    for id in offerIDs where seenOffer.insert(id).inserted {
      published = demand(.offer(id)) || published
    }

    if let openProduct {
      productDemandStamps[openProduct] = clock
      published = demand(.detail(openProduct)) || published
    }

    return published
  }

  /// Whether any screen that reads catalog-derived state is held.
  ///
  /// The catalog is at the root of everything except the account, so it is
  /// demanded as soon as anything that reads it is on screen and not before.
  private var holdsAnyScreen: Bool {
    holds.contains(.browse) || holds.contains(.search) || holds.contains(.cart)
      || holds.contains(.detail)
  }

  /// Marks one slot demanded and selects it if its plan has moved.
  ///
  /// - Parameter key: Which slot.
  /// - Returns: Whether the selection published a resting value synchronously.
  private func demand(_ key: StorefrontStateGraphAsyncKey) -> Bool {
    var slot = slots[key] ?? StorefrontStateGraphSlot()
    slot.lastDemandedAt = clock
    let plan = currentPlan(for: key)
    guard slot.plan != plan else {
      slots[key] = slot
      return false
    }
    slot.generation += 1
    slot.plan = plan
    slots[key] = slot
    return begin(key: key, plan: plan, generation: slot.generation)
  }

  /// Forces a new generation for one slot, whatever its plan says.
  ///
  /// What a pull-to-refresh is: the plan has not moved, so ``demand(_:)`` would
  /// do nothing, and the point is to ask the same question again anyway.
  ///
  /// - Parameter key: Which slot.
  /// - Returns: The generation this call started.
  @discardableResult
  private func forceRefresh(_ key: StorefrontStateGraphAsyncKey) -> Int {
    let plan = currentPlan(for: key)
    var slot = slots[key] ?? StorefrontStateGraphSlot()
    slot.generation += 1
    slot.plan = plan
    slot.lastDemandedAt = clock
    slots[key] = slot
    _ = begin(key: key, plan: plan, generation: slot.generation)
    return slot.generation
  }

  /// What one slot would ask for, given the graph as it stands.
  ///
  /// - Parameter key: Which slot.
  /// - Returns: The plan its selector produces.
  private func currentPlan(for key: StorefrontStateGraphAsyncKey) -> StorefrontStateGraphPlan {
    switch key {
    case .catalog: .catalog
    case .account: .account
    case .searchIndex: nodes.searchIndexPlan.wrappedValue
    case .suggestions: nodes.suggestionsPlan.wrappedValue
    case .recommendations: nodes.recommendationsPlan.wrappedValue
    case .shippingQuote: nodes.shippingQuotePlan.wrappedValue
    case .taxQuote: nodes.taxQuotePlan.wrappedValue
    case .inventory(let id): nodes.inventoryPlan(id).wrappedValue
    case .offer(let id): nodes.offerPlan(id).wrappedValue
    case .detail(let id): nodes.detailPlan(id).wrappedValue
    }
  }

  /// Starts one generation of one slot, or publishes its resting value.
  ///
  /// Every dependency the request needs is captured here, synchronously and on
  /// the MainActor, before any task exists — the same discipline Cog's async
  /// declarations follow when they read their inputs and then hand back
  /// `.run { @concurrent … }`. The request is registered with the script
  /// through ``StorefrontService/schedule(_:)`` in the same synchronous step,
  /// which is what lets the scripted driver see and release work whose task has
  /// not reached the service yet.
  ///
  /// - Parameters:
  ///   - key: Which slot.
  ///   - plan: The plan this generation was selected for.
  ///   - generation: The generation being started.
  /// - Returns: Whether a resting value was published synchronously.
  private func begin(
    key: StorefrontStateGraphAsyncKey,
    plan: StorefrontStateGraphPlan,
    generation: Int
  ) -> Bool {
    if case .recommendations = key { supersedeRecommendationRefreshes(before: generation) }
    let service = service

    switch key {
    case .catalog:
      start(key: key, generation: generation, id: .catalog) { @concurrent in
        try await service.catalog()
      } publish: { [unowned self] snapshot in
        publishCatalog(snapshot)
      }
      return false

    case .account:
      start(key: key, generation: generation, id: .account) { @concurrent in
        try await service.account()
      } publish: { [unowned self] shopper in
        publishAccount(shopper)
      }
      return false

    case .searchIndex:
      let products = nodes.catalogProducts.wrappedValue
      start(key: key, generation: generation, id: .searchIndex) { @concurrent in
        try await service.searchIndex(products: products)
      } publish: { [unowned self] index in
        publish(index, into: nodes.searchIndex)
      }
      return false

    case .suggestions:
      guard case .suggestions(let query, _) = plan else {
        return publish([], into: nodes.suggestions)
      }
      let products = nodes.catalogProducts.wrappedValue
      start(key: key, generation: generation, id: .suggestions(query: query)) { @concurrent in
        try await service.suggestions(query: query, products: products)
      } publish: { [unowned self] values in
        publish(values, into: nodes.suggestions)
      }
      return false

    case .recommendations:
      guard case .recommendations(let accountID, _) = plan,
        let shopper = nodes.signedInShopper.wrappedValue
      else {
        return publish([], into: nodes.recommendations)
      }
      let products = nodes.catalogProducts.wrappedValue
      start(
        key: key,
        generation: generation,
        id: .recommendations(accountID: accountID),
        work: { @concurrent in
          try await service.recommendations(products: products, shopper: shopper)
        },
        publish: { [unowned self] values in
          publish(values, into: nodes.recommendations)
        },
        resolve: { [unowned self] outcome in
          resolveRecommendationRefresh(generation: generation, outcome: outcome)
        }
      )
      return false

    case .shippingQuote:
      guard case .shippingQuote(let subtotal, let address, let method, let lineCount) = plan else {
        return publish(.pending, into: nodes.shippingQuote)
      }
      let id = StorefrontRequestID.shippingQuote(
        subtotalCents: subtotal,
        market: address.market,
        method: method
      )
      start(key: key, generation: generation, id: id) { @concurrent in
        try await service.shippingQuote(
          subtotalCents: subtotal,
          address: address,
          method: method,
          lineCount: lineCount
        )
      } publish: { [unowned self] quote in
        publish(quote, into: nodes.shippingQuote)
      }
      return false

    case .taxQuote:
      guard case .taxQuote(let subtotal, let address) = plan else {
        return publish(.pending, into: nodes.taxQuote)
      }
      let id = StorefrontRequestID.taxQuote(subtotalCents: subtotal, market: address.market)
      start(key: key, generation: generation, id: id) { @concurrent in
        try await service.taxQuote(discountedSubtotalCents: subtotal, address: address)
      } publish: { [unowned self] quote in
        publish(quote, into: nodes.taxQuote)
      }
      return false

    case .inventory(let productID):
      guard case .inventory(_, let inventoryGeneration) = plan else {
        return publish(.unknown, into: nodes.inventory(productID))
      }
      let id = StorefrontRequestID.inventory(id: productID, generation: inventoryGeneration)
      start(key: key, generation: generation, id: id) { @concurrent in
        try await service.inventory(for: productID, generation: inventoryGeneration)
      } publish: { [unowned self] reading in
        publish(reading, into: nodes.inventory(productID))
      }
      return false

    case .offer(let productID):
      guard case .offer = plan, let shopper = nodes.signedInShopper.wrappedValue else {
        return publish(.none, into: nodes.offer(productID))
      }
      start(key: key, generation: generation, id: .offer(id: productID)) { @concurrent in
        try await service.offer(for: productID, shopper: shopper)
      } publish: { [unowned self] offer in
        publish(offer, into: nodes.offer(productID))
      }
      return false

    case .detail(let productID):
      guard case .detail = plan,
        let product = nodes.productIndex.wrappedValue[productID]
      else {
        return publish(.empty, into: nodes.detail(productID))
      }
      start(key: key, generation: generation, id: .detail(id: productID)) { @concurrent in
        try await service.detail(for: product)
      } publish: { [unowned self] detail in
        publish(detail, into: nodes.detail(productID))
      }
      return false
    }
  }

  /// Registers one request with the script and launches its task.
  ///
  /// ``StorefrontService/schedule(_:)`` is called synchronously, on the
  /// MainActor, strictly before the task exists — the scripted driver depends
  /// on that gap being closed, because otherwise it could try to release work
  /// the script has not seen yet.
  ///
  /// - Parameters:
  ///   - key: Which slot this generation belongs to.
  ///   - generation: The generation being started.
  ///   - id: The semantic request being made.
  ///   - work: The request itself, `@concurrent` so its kernel runs off the
  ///     MainActor exactly as Cog's `.run { @concurrent … }` does.
  ///   - publish: What to do with an accepted value, on the MainActor.
  ///   - resolve: How to resolve a demand handle bound to this generation.
  private func start<Value: Sendable>(
    key: StorefrontStateGraphAsyncKey,
    generation: Int,
    id: StorefrontRequestID,
    work: @escaping @Sendable () async throws -> Value,
    publish: @escaping @MainActor (Value) -> Void,
    resolve: @escaping @MainActor (StorefrontRefreshOutcome<Value>) -> Void = { _ in }
  ) {
    service.schedule(id)
    Task { [self] in
      do {
        let value = try await work()
        complete(
          key: key,
          generation: generation,
          result: .success(value),
          publish: publish,
          resolve: resolve
        )
      } catch {
        complete(
          key: key,
          generation: generation,
          result: .failure(error),
          publish: publish,
          resolve: resolve
        )
      }
    }
  }

  /// Decides what to do with one completed request, and says that it decided.
  ///
  /// Acceptance is by generation, captured synchronously at selection time.
  /// Task cancellation plays no part: the script leaves cancelled requests
  /// suspended by default, so a superseded request completes here later and is
  /// refused on its own terms rather than by having been cancelled.
  ///
  /// The completion signal fires on **both** branches and exactly once, which
  /// is what makes ``settlingOneAsyncResult(_:)`` a definite signal for a step
  /// whose whole subject is a result the runtime refuses.
  ///
  /// - Parameters:
  ///   - key: Which slot this result belongs to.
  ///   - generation: The generation it was started for.
  ///   - result: What the request produced.
  ///   - publish: What to do with an accepted value.
  ///   - resolve: How to resolve a demand handle bound to this generation.
  private func complete<Value: Sendable>(
    key: StorefrontStateGraphAsyncKey,
    generation: Int,
    result: Result<Value, any Error>,
    publish: @MainActor (Value) -> Void,
    resolve: @MainActor (StorefrontRefreshOutcome<Value>) -> Void
  ) {
    let signal = armedCompletionSignal
    armedCompletionSignal = nil
    defer { signal?.signal() }

    guard slots[key]?.generation == generation else {
      // Newer work, an invalidated selection, or a released slot made this
      // generation stale before it could publish.
      resolve(.superseded)
      return
    }

    switch result {
    case .success(let value):
      publish(value)
      resolve(.success(value))
    case .failure(let error):
      // A failed request publishes nothing: a value read is total and rests on
      // the last accepted success, exactly as Cog's does.
      resolve(.failure(error))
    }
    settle()
  }

  /// Writes one accepted value into its node.
  ///
  /// - Parameters:
  ///   - value: The accepted value.
  ///   - node: Where it belongs.
  /// - Returns: Whether it differed from what was already there.
  @discardableResult
  private func publish<Value: Equatable & Sendable>(
    _ value: Value,
    into node: Stored<Value>
  ) -> Bool {
    var changed = false
    withGraphTransaction {
      changed = node.wrappedValue != value
      node.wrappedValue = value
    }
    return changed
  }

  /// Accepts one catalog and records that the catalog moved.
  ///
  /// The revision is what lets an asynchronous plan notice a new catalog
  /// without carrying the products themselves. It advances only when the
  /// snapshot genuinely differs, so a reload returning an equal catalog leaves
  /// every plan downstream of it exactly where it was — the same thing Cog's
  /// equality gate on `storefrontCatalogProductsCog` achieves.
  ///
  /// - Parameter snapshot: The accepted catalog.
  private func publishCatalog(_ snapshot: CatalogSnapshot) {
    withGraphTransaction {
      guard nodes.catalog.wrappedValue != snapshot else { return }
      nodes.catalog.wrappedValue = snapshot
      nodes.catalogRevision.wrappedValue += 1
    }
  }

  /// Accepts one account response and runs the account observer.
  ///
  /// - Parameter shopper: The accepted shopper.
  private func publishAccount(_ shopper: Shopper) {
    var changed = false
    withGraphTransaction {
      changed = nodes.account.wrappedValue != shopper
      nodes.account.wrappedValue = shopper
    }
    if changed { runAccountObserver(shopper) }
  }

  /// Runs the account observer once.
  ///
  /// Deliberately a write rather than a derivation: signing out is a local
  /// action that must not wait on a request, so the accepted response is copied
  /// into the shopper source and everything downstream reads that one writable
  /// fact.
  ///
  /// - Parameter shopper: What the observer saw.
  private func runAccountObserver(_ shopper: Shopper?) {
    sink.recordAccount()
    withGraphTransaction { nodes.signedInShopper.wrappedValue = shopper }
  }

  /// Resolves the demand handle bound to one generation, if one is waiting.
  ///
  /// - Parameters:
  ///   - generation: Which generation resolved.
  ///   - outcome: What it produced.
  private func resolveRecommendationRefresh(
    generation: Int,
    outcome: StorefrontRefreshOutcome<[ProductID]>
  ) {
    guard let promise = recommendationRefreshes.removeValue(forKey: generation) else { return }
    promise.resolve(outcome)
  }

  /// Resolves every recommendation handle older than `generation` as superseded.
  ///
  /// At the moment of replacement, not when the abandoned request eventually
  /// completes — which in this script it may never do.
  ///
  /// - Parameter generation: The generation that replaced them.
  private func supersedeRecommendationRefreshes(before generation: Int) {
    for (older, promise) in recommendationRefreshes where older < generation {
      recommendationRefreshes.removeValue(forKey: older)
      promise.resolve(.superseded)
    }
  }

  // MARK: - Release

  /// Drops the per-product state nothing has demanded since grace elapsed.
  ///
  /// swift-state-graph has no lifetime model, so this sweep is the port's own
  /// and its cost belongs to the port. It is an ordinary TTL eviction — a
  /// demand stamp per product, a deadline, and a pass — which is what a careful
  /// team writes and what makes
  /// ``StorefrontRuntimeSemantics/releasesUnobservedValues`` an honest claim.
  /// An unconditional clear would make the teardown phase's release proof
  /// vacuous and is not what this does: a product still on screen, still in the
  /// cart, or still open keeps everything it has.
  private func sweepReleasableProducts() {
    let demanded = currentlyDemandedProductIDs()
    var releasable: [ProductID] = []
    for id in nodes.materializedProductIDs where !demanded.contains(id) {
      let stamp = productDemandStamps[id] ?? .zero
      if stamp + grace <= clock { releasable.append(id) }
    }
    for id in releasable {
      nodes.release(id)
      productDemandStamps.removeValue(forKey: id)
      slots.removeValue(forKey: .inventory(id))
      slots.removeValue(forKey: .offer(id))
      slots.removeValue(forKey: .detail(id))
    }
  }

  /// Which products anything currently demands per-product state for.
  ///
  /// The same three sources ``pollAsyncDemand()`` polls, read from the settled
  /// graph rather than remembered, so a sweep can never free something the very
  /// next render would ask for.
  ///
  /// - Returns: The demanded products.
  private func currentlyDemandedProductIDs() -> Set<ProductID> {
    var demanded: Set<ProductID> = []
    if holds.contains(.browse) { demanded.formUnion(nodes.prefetchProductIDs.wrappedValue) }
    if holds.contains(.cart) { demanded.formUnion(nodes.cartLineIDs.wrappedValue) }
    if holds.contains(.detail), let open = nodes.selectedProduct.wrappedValue {
      demanded.insert(open)
    }
    return demanded
  }

  // MARK: - Rendering

  /// Runs every held observer once.
  ///
  /// This is the settlement barrier as much as it is the observation: reading a
  /// root `Computed` recomputes its whole upstream funnel synchronously on this
  /// thread, so when this returns the graph is settled and the sink holds what
  /// a screen would be showing.
  private func render() {
    if holds.contains(.browse) { renderBrowse() }
    if holds.contains(.search) { renderSearch() }
    if holds.contains(.cart) { renderCart() }
    if holds.contains(.detail) { renderDetail() }
  }

  /// Reads the browse screen and deposits it when it changed.
  ///
  /// The prefetch margin is read as well as the window, and reading it is what
  /// establishes demand for its rows' inventory and offers — a list that
  /// demanded only what is on screen would show a price arriving one frame
  /// after the row it belongs to.
  private func renderBrowse() {
    let visible = nodes.visibleProductIDs.wrappedValue
    var checksum = 0
    for id in visible {
      let row = nodes.productRow(id).wrappedValue
      checksum = StorefrontKernels.mix(checksum, id.raw)
      checksum = StorefrontKernels.mix(checksum, row.priceCents)
      checksum = StorefrontKernels.mix(checksum, row.availableUnits)
      checksum = StorefrontKernels.mix(checksum, row.badges.rawValue)
      checksum = StorefrontKernels.mix(checksum, row.cartQuantity)
    }
    let demanded = nodes.prefetchProductIDs.wrappedValue
    for id in demanded { _ = nodes.productRow(id).wrappedValue }

    let payload = BrowsePayload(visible: visible, demanded: demanded, checksum: checksum)
    guard payload != lastBrowsePayload else { return }
    lastBrowsePayload = payload
    sink.recordBrowse(visible: visible, demanded: demanded, checksum: checksum)
  }

  /// Reads the search suggestions and deposits them when they changed.
  private func renderSearch() {
    let suggestions = nodes.suggestions.wrappedValue
    guard suggestions != lastSuggestions else { return }
    lastSuggestions = suggestions
    sink.recordSearch(suggestions: suggestions)
  }

  /// Reads the cart's money and readiness and deposits them when they changed.
  private func renderCart() {
    let payload = CartPayload(
      total: nodes.orderTotal.wrappedValue,
      readiness: nodes.checkoutReadiness.wrappedValue
    )
    guard payload != lastCartPayload else { return }
    lastCartPayload = payload
    sink.recordCart(total: payload.total, readiness: payload.readiness)
  }

  /// Reads the detail screen and deposits it when it changed.
  ///
  /// Reading nothing but the selection when no product is open is what lets the
  /// detail payload and the recommendation shelf become releasable after the
  /// shopper navigates away.
  private func renderDetail() {
    let payload: DetailPayload
    if let selected = nodes.selectedProduct.wrappedValue {
      payload = DetailPayload(
        reviewCount: nodes.detail(selected).wrappedValue.reviewCount,
        recommendations: nodes.recommendations.wrappedValue
      )
    } else {
      payload = DetailPayload(reviewCount: 0, recommendations: [])
    }
    guard payload != lastDetailPayload else { return }
    lastDetailPayload = payload
    sink.recordDetail(
      reviewCount: payload.reviewCount,
      recommendations: payload.recommendations
    )
  }

  nonisolated deinit {}
}
