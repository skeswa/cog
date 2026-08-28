import Observation
public import StorefrontWorkload

/// The Storefront workload over raw Swift Observation, recomputing everything
/// on every read.
///
/// This is the **floor**. Seventeen `@Observable` stored properties hold the
/// writable facts, ten more hold the last accepted asynchronous response, and
/// every one of the thirty-two derived values the Cog port declares is an
/// ordinary Swift function that runs end to end whenever it is called. There is
/// no cache, no memo, no dirty bit, no version stamp, and no dependency edge
/// anywhere in the derivation layer. A browse render runs the whole search
/// funnel twice, once for the visible window and once for the prefetch margin,
/// and runs the seventeen-stage pricing ladder from its base price for every
/// demanded row, twice for each row whose price and badges are both wanted.
///
/// That is the point. Its numbers are what this workload costs with Observation
/// and nothing else, so the cost of Cog's machinery can be read against them
/// rather than against an intuition. It is expected to be slow on the pricing
/// ladder and on search over the full catalog, and its declared semantics differ
/// from Cog's on the invalidation checkpoints, see ``descriptor``. Both are
/// results, not defects.
///
/// ## Disclosed deviations
///
/// Three, and each is written down here rather than buried:
///
/// 1. **Rendering is port-owned, not driven by Observation's change callback.**
///    `withObservationTracking`'s `onChange` fires *before* the mutation that
///    triggered it has completed, and re-registering from inside it is a
///    scheduling decision rather than a settlement. The trace reads the sink on
///    the line after a verb returns, so every runtime must settle synchronously.
///    Each verb therefore applies its writes and then renders exactly once, at
///    the close of that one transaction. The tracking scope is kept anyway, with
///    an empty callback, so the registrar's registration and notification costs
///    both stay inside the sample and this port stays genuinely raw instead of
///    hiding a bespoke invalidation graph behind the scope.
///
/// 2. **A request-identity cache in the asynchronous layer**, and only there.
///    Without it the port would spin, render, request, publish, render,
///    request, because nothing else could tell it that this is the same
///    question it already asked. It caches no derived value. See
///    ``RawObservationAsyncDemand``.
///
/// 3. **Demand is collected during the observer pass rather than by a separate
///    pass before it.** Each asynchronous read records the identity it wants;
///    the render reconciles those identities immediately afterwards, inside the
///    same synchronous settlement, before the verb returns. Computing the
///    demand set in a pass of its own would mean running the whole funnel a
///    third time per render, which would inflate the floor with work no
///    implementation performs.
///
/// ## Identity and ownership
///
/// One instance per session, created by
/// ``make(profile:service:initialWindow:holds:sink:grace:)`` and retained by the
/// driver. It owns the model, the request bookkeeping, and every task it
/// launches; the driver owns the script, the sink, and the shadow world.
///
/// ## Isolation
///
/// MainActor-confined. Every verb writes on the MainActor, every render reads on
/// it, and every publish-or-discard decision is taken on it. The heavy kernels
/// run off it, inside `@concurrent` request bodies, exactly as the Cog port's
/// do.
///
/// ## Turn and settlement ordering
///
/// A verb is one transaction: it applies every write it owns and then renders
/// once, so a multi-source verb never renders an intermediate screen. Reads
/// taken inside a verb see that verb's own staged writes for free, because the
/// sources are plain stored properties. When a verb returns the port has
/// settled: every held observer has already run and deposited into the sink.
///
/// ## Cancellation and races
///
/// Nothing here relies on task cancellation. A completed response carries the
/// generation captured synchronously when it was selected and is published only
/// if that generation is still current, so a superseded result is refused by
/// identity rather than by cooperation. ``StorefrontScript`` leaves cancelled
/// requests suspended by default precisely so that a port relying on
/// cancellation would fail the stale-result checkpoint instead of passing it by
/// luck.
///
/// `nonisolated deinit` per the repository convention.
@MainActor
public final class RawObservationStorefrontRuntime: StorefrontRuntime {
  /// The per-generation demand handle this runtime hands back.
  public typealias Refresh = RawObservationStorefrontRefresh

  /// What raw Observation is called in a benchmark name, and what it guarantees.
  ///
  /// Every value is measured rather than aspirational, and three of them differ
  /// from Cog's on purpose:
  ///
  /// - `browseRunsPerEqualWrite: 1`, writing the sort mode that is already
  ///   selected renders anyway. The port cannot tell that nothing changed;
  ///   knowing that is exactly what an invalidation graph is for, and declaring
  ///   `0` here would be a lie about a claim the filter phase measures.
  /// - `browseRunsPerUndemandedInvalidation: 1`, an inventory burst that
  ///   touches only offscreen products still renders once, for the same reason.
  /// - `releasesUnobservedValues: false`, there is no lifetime model here
  ///   because there is nothing to release: no derived value survives the call
  ///   that computed it, and an accepted response is kept for the session. The
  ///   teardown phase records an explicit skip for its release proof rather than
  ///   passing it for the wrong reason.
  ///
  /// `declaredUndemandedRequestStarts: 0` matches Cog, and the results table
  /// **must** annotate why: it is true here for a *structural* reason rather
  /// than a state-management one. The render walks the visible window widened by
  /// the prefetch margin, so a product outside it is never asked about and its
  /// invalidated inventory generation is simply never consulted. Reporting that
  /// as a tie with Cog's demand-driven laziness, without the annotation, would
  /// be dishonest.
  ///
  /// `accountRunsThroughSignIn: 2` and `browseRunsPerContentChangingTurn: 1`
  /// coincide with Cog for a reason worth stating: one transaction is one
  /// render, and every held observer runs in every render, so registration
  /// accounts for the first account run and the accepted response for the
  /// second.
  public static let descriptor = StorefrontRuntimeDescriptor(
    slug: "observation-raw",
    displayName: "raw @Observable",
    semantics: StorefrontRuntimeSemantics(
      browseRunsPerContentChangingTurn: 1,
      browseRunsPerEqualWrite: 1,
      browseRunsPerUndemandedInvalidation: 1,
      accountRunsThroughSignIn: 2,
      declaredUndemandedRequestStarts: 0,
      releasesUnobservedValues: false,
      refusesStaleResultsByGeneration: true,
      hasPerGenerationRefreshHandles: true
    )
  )

  /// The shopper the pricing ladder uses before an account response lands.
  ///
  /// Tier `guest` and zero loyalty points, which is what the Cog declarations'
  /// `?? .guest` and `?? 0` amount to. The remaining fields are never read by
  /// any pricing policy, so they are the emptiest values that type admits
  /// rather than a fabricated identity.
  static let guestShopper = Shopper(
    accountID: 0,
    name: "",
    tier: .guest,
    taste: StorefrontFeatureVector(0, 0, 0, 0, 0, 0, 0, 0),
    loyaltyPoints: 0
  )

  /// Every writable fact and every accepted response.
  let model: RawObservationStorefrontModel

  /// Which durable observers this session registered.
  let holds: StorefrontHolds

  /// Where those observers deposit what they read.
  let sink: StorefrontSink

  /// Per-slot request bookkeeping: what was asked, at which generation.
  var records: [RawObservationAsyncSlot: RawObservationAsyncRecord] = [:]

  /// Identities the current observer pass wants.
  ///
  /// Rebuilt every render and consumed by the reconciliation that follows it.
  /// Kept as a stored property, rather than threaded through every derivation,
  /// so that a read reached from anywhere in the funnel records the same way.
  var pendingDemand: [RawObservationAsyncSlot: RawObservationAsyncDemand] = [:]

  /// Slots the current observer pass short-circuited.
  ///
  /// A guarded read asks for nothing and rests on its declaration default, so
  /// it is recorded separately from a demand rather than as a missing one:
  /// "nobody looked" and "somebody looked and there is nothing to fetch" are
  /// different facts, and only the second resets the value.
  var pendingGuards: Set<RawObservationAsyncSlot> = []

  /// Whether a render is in progress.
  ///
  /// Suppresses the reentrant render a write taken *inside* an observer would
  /// otherwise cause, the account observer writes the shopper it just accepted
  ///, so one transaction stays one settlement.
  private var isRendering = false

  /// Whether asynchronous reads should record what they want.
  ///
  /// True only during the observer pass. A settled inspection, the two peeks
  /// the trace takes, must create no demand, and gating on this is what keeps
  /// a peek from starting a request the session never asked for.
  var isCollectingDemand = false

  /// How many distinct catalogs have been accepted.
  ///
  /// Advanced only when an accepted catalog actually differs from the one in
  /// hand, which is what a hand-written app means by `didAcceptCatalog`. Every
  /// asynchronous slot that reads the catalog but whose request identity does
  /// not mention it, the search index above all, carries this number in its
  /// demand.
  var catalogEpoch = 0

  /// How many distinct signed-in shoppers have been written.
  ///
  /// The same device for the shopper, whose changes reach the offers and the
  /// recommendations without appearing in either request identity.
  var shopperEpoch = 0

  /// The newest unresolved recommendation demand, and the generation it names.
  ///
  /// Retained so that the *next* demand can resolve it as superseded at the
  /// moment of replacement, which is what makes the teardown phase's checkpoint
  /// resolve without a clock or a poll.
  var pendingRecommendationsRefresh: (generation: Int, handle: RawObservationStorefrontRefresh)?

  /// The barrier a settlement is currently waiting on, if any.
  ///
  /// Armed before the release that produces a result and fired by the result's
  /// epilogue on both the publish and the discard branch, because a refused
  /// stale result is exactly as much of a decision as an accepted one.
  var armedCompletionSignal: StorefrontCompletionSignal?

  /// Creates a runtime around a model whose initial state is already written.
  ///
  /// Private because a session's model must be the one
  /// ``make(profile:service:initialWindow:holds:sink:grace:)`` prepared: the
  /// service and the starting row window are written before the first render,
  /// so no held observer ever sees the pre-initial world on its way past.
  ///
  /// - Parameters:
  ///   - model: The prepared model.
  ///   - holds: Which durable observers to run.
  ///   - sink: Where those observers deposit what they read.
  private init(
    model: RawObservationStorefrontModel,
    holds: StorefrontHolds,
    sink: StorefrontSink
  ) {
    self.model = model
    self.holds = holds
    self.sink = sink
  }

  // MARK: - Construction

  /// Builds a fresh, isolated runtime whose initial state has already settled.
  ///
  /// The service and the starting window are written before the first render,
  /// and that first render is where every held observer runs once, which is
  /// what the bootstrap phase's browse-run count is a claim about.
  ///
  /// - Parameters:
  ///   - profile: The world's size. Must be the profile the service serves;
  ///     this port reads it back off the service, exactly as the Cog port reads
  ///     it off its service source.
  ///   - service: The request boundary to install.
  ///   - initialWindow: The row window the list starts at.
  ///   - holds: Which durable observers to run.
  ///   - sink: Where those observers deposit what they read.
  ///   - grace: Ignored. This port has no lifetime model and declares
  ///     ``StorefrontRuntimeSemantics/releasesUnobservedValues`` `false`; there
  ///     is nothing cached for a grace period to expire.
  /// - Returns: A live runtime whose initial state has settled.
  public static func make(
    profile: StorefrontProfile,
    service: StorefrontService,
    initialWindow: RowWindow,
    holds: StorefrontHolds,
    sink: StorefrontSink,
    grace: Duration
  ) -> RawObservationStorefrontRuntime {
    guard service.profile == profile else {
      fatalError(
        """
        The raw Observation Storefront runtime was asked for a \(profile.name) session over a \
        \(service.profile.name) service. The profile decides the catalog, the pricing ladder, and \
        every expectation derived from them, so a session built over two of them would be \
        measuring neither.
        """
      )
    }
    let model = RawObservationStorefrontModel(service: service)
    model.rowWindow = initialWindow
    let runtime = RawObservationStorefrontRuntime(model: model, holds: holds, sink: sink)
    runtime.render()
    return runtime
  }

  // MARK: - Domain operations

  /// Records the account response this runtime accepted, or signs out.
  ///
  /// Called by this runtime's own account observer, and by nothing else in the
  /// trace. The shopper epoch advances only when the value actually changes,
  /// because the observer runs in every render and re-asking the service for
  /// every demanded offer on every frame is not a floor, it is a defect.
  ///
  /// - Parameter shopper: The signed-in shopper, or `nil`.
  public func signIn(as shopper: Shopper?) {
    mutate {
      guard model.signedInShopper != shopper else { return }
      model.signedInShopper = shopper
      shopperEpoch += 1
    }
  }

  /// Records the rows the list has materialized.
  ///
  /// - Parameter window: The new window.
  public func scrollRows(to window: RowWindow) {
    mutate { model.rowWindow = window }
  }

  /// Replaces the search field's contents.
  ///
  /// - Parameter text: The field's new contents.
  public func typeSearchQuery(_ text: String) {
    mutate { model.searchQuery = text }
  }

  /// Applies the browse screen's filters and resets the window, in one settle.
  ///
  /// Four sources in one transaction, and the window's new length is read back
  /// out of this transaction's own staged value.
  ///
  /// - Parameters:
  ///   - category: The category to filter to, or `nil` for all.
  ///   - sortMode: How to order results.
  ///   - inStockOnly: Whether to hide out-of-stock products.
  public func applyBrowseFilters(category: CategoryID?, sortMode: SortMode, inStockOnly: Bool) {
    mutate {
      model.selectedCategory = category
      model.sortMode = sortMode
      model.inStockOnly = inStockOnly
      model.rowWindow = RowWindow(offset: 0, length: model.rowWindow.length)
    }
  }

  /// Selects one category without disturbing the rest of the filter bar.
  ///
  /// - Parameter category: The category, or `nil` for all.
  public func selectCategory(_ category: CategoryID?) {
    mutate { model.selectedCategory = category }
  }

  /// Chooses how results are ordered.
  ///
  /// Writing the mode that is already selected renders anyway; this port has no
  /// equality gate and declares `browseRunsPerEqualWrite: 1` for exactly that.
  ///
  /// - Parameter mode: The sort mode.
  public func selectSortMode(_ mode: SortMode) {
    mutate { model.sortMode = mode }
  }

  /// Shows or hides out-of-stock products.
  ///
  /// - Parameter isOn: Whether to hide them.
  public func setInStockOnly(_ isOn: Bool) {
    mutate { model.inStockOnly = isOn }
  }

  /// Toggles one product's favorite flag.
  ///
  /// Reads its own staged value, so two toggles in one settle would cancel
  /// rather than both setting `true`.
  ///
  /// - Parameter id: Which product.
  public func toggleFavorite(_ id: ProductID) {
    mutate { model.favorites[id] = !(model.favorites[id] ?? false) }
  }

  /// Opens a product's detail screen and records that it was viewed.
  ///
  /// Two sources, one transaction: a split would render the detail screen
  /// against a stale rank and run the recency-dependent pricing stage twice for
  /// one navigation.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - rank: The recency rank to record; larger is more recent.
  public func openProduct(_ id: ProductID, rank: Int) {
    mutate {
      model.selectedProduct = id
      model.recentlyViewedRanks[id] = rank
    }
  }

  /// Returns to the browse screen.
  public func closeProduct() {
    mutate { model.selectedProduct = nil }
  }

  /// Selects a variant of one product.
  ///
  /// - Parameters:
  ///   - variantIndex: Which variant.
  ///   - id: Which product.
  public func selectVariant(_ variantIndex: Int, for id: ProductID) {
    mutate { model.selectedVariants[id] = variantIndex }
  }

  /// Adds a product to the cart, or increases its quantity.
  ///
  /// Membership and quantity are two sources and this is one action, so it is
  /// one transaction. Writing them separately would let a settled state observe
  /// a product that is in the cart with quantity zero, and would start a
  /// shipping and tax quote generation for that impossible subtotal.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - quantity: How many to add.
  public func addToCart(_ id: ProductID, quantity: Int) {
    mutate {
      let existing = model.cartQuantities[id] ?? 0
      model.cartQuantities[id] = existing + quantity
      if existing == 0 { model.cartContents.append(id) }
    }
  }

  /// Sets one line's quantity, removing the line at zero.
  ///
  /// - Parameters:
  ///   - quantity: The new quantity; zero or less removes the line.
  ///   - id: Which product.
  public func setCartQuantity(_ quantity: Int, for id: ProductID) {
    mutate {
      model.cartQuantities[id] = max(0, quantity)
      if quantity <= 0 {
        model.cartContents.removeAll { $0 == id }
      } else if !model.cartContents.contains(id) {
        model.cartContents.append(id)
      }
    }
  }

  /// Applies or clears a coupon.
  ///
  /// - Parameter coupon: The typed coupon, or `nil` to clear it.
  public func applyCoupon(_ coupon: CouponCode?) {
    mutate { model.coupon = coupon }
  }

  /// Chooses where the order ships.
  ///
  /// - Parameter address: The address.
  public func selectShippingAddress(_ address: ShippingAddress) {
    mutate { model.shippingAddress = address }
  }

  /// Chooses how the order ships.
  ///
  /// - Parameter method: The method.
  public func selectShippingMethod(_ method: ShippingMethod) {
    mutate { model.shippingMethod = method }
  }

  /// Publishes one inventory burst.
  ///
  /// Every touched product's generation advances in one transaction, which is
  /// what a warehouse feed looks like. This port renders once for the burst
  /// whether or not anything on screen was touched, see
  /// ``StorefrontRuntimeSemantics/browseRunsPerUndemandedInvalidation``, but it
  /// still asks the service for nothing on behalf of the offscreen half,
  /// because that half is outside the window the render walks.
  ///
  /// - Parameters:
  ///   - ids: The products the feed touched.
  ///   - generation: The generation to advance them to.
  public func publishInventoryBurst(_ ids: [ProductID], generation: Int) {
    mutate {
      for id in ids { model.inventoryGenerations[id] = generation }
    }
  }

  // MARK: - Asynchronous demand

  /// Re-demands the catalog.
  public func refreshCatalog() {
    forceDemand(.catalog, request: .catalog)
  }

  /// Re-demands one product's inventory.
  ///
  /// - Parameter id: Which product.
  public func refreshInventory(for id: ProductID) {
    let generation = model.inventoryGenerations[id] ?? 0
    forceDemand(.inventory(id), request: .inventory(id: id, generation: generation))
  }

  /// Demands fresh recommendations and hands back that exact demand's handle.
  ///
  /// Demanded unconditionally rather than only when a detail screen is open,
  /// because an explicit re-demand is a user action rather than a consequence of
  /// what is on screen. A signed-out shopper has nothing to fetch, so the handle
  /// is born resolved rather than left to hang.
  ///
  /// - Returns: A handle bound to this generation, never to a later one.
  @discardableResult
  public func refreshRecommendations() -> RawObservationStorefrontRefresh {
    guard let shopper = model.signedInShopper else {
      var record = records[.recommendations] ?? RawObservationAsyncRecord()
      record.refreshEpoch += 1
      record.demand = nil
      record.generation += 1
      records[.recommendations] = record
      supersedePendingRefresh(for: .recommendations)
      model.recommendations = []
      return RawObservationStorefrontRefresh(resolved: .success([]))
    }
    let request = StorefrontRequestID.recommendations(accountID: shopper.accountID)
    var record = records[.recommendations] ?? RawObservationAsyncRecord()
    record.refreshEpoch += 1
    record.demand = RawObservationAsyncDemand(
      request: request,
      catalogEpoch: catalogEpoch,
      shopperEpoch: shopperEpoch,
      refreshEpoch: record.refreshEpoch
    )
    record.generation += 1
    records[.recommendations] = record
    supersedePendingRefresh(for: .recommendations)
    let handle = RawObservationStorefrontRefresh()
    pendingRecommendationsRefresh = (record.generation, handle)
    start(.recommendations, request: request, generation: record.generation)
    return handle
  }

  // MARK: - Settled inspection

  /// The price this runtime currently reports for one product.
  ///
  /// Untracked because the whole derivation layer is untracked and because the
  /// read is taken outside an observer pass, so it records no demand and starts
  /// no request. It is also the full seventeen-stage ladder, run here and now.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  public func peekEffectivePrice(of id: ProductID) -> Int {
    effectivePrice(of: id)
  }

  /// The promotion plan this runtime currently reports.
  ///
  /// - Returns: The settled promotion plan.
  public func peekPromotionPlan() -> PromotionPlan {
    promotionPlan()
  }

  /// Computes the ranked product list and returns it.
  ///
  /// The footprint cut's subject, and this port's honest answer to it: the read
  /// runs the whole funnel and then keeps **nothing**. There is no materialized
  /// search index, candidate set, eligibility map, score table, or ranking left
  /// behind to weigh, because this port never materializes any of them, which
  /// is why its footprint number is small and its time number is not.
  ///
  /// - Returns: The ranked product identifiers, in rank order.
  @discardableResult
  public func demandRankedProductIDs() -> [ProductID] {
    rankedProductIDs()
  }

  // MARK: - Settlement barriers

  /// Runs `body` and returns once one asynchronous result has reached this
  /// runtime's publish decision.
  ///
  /// The barrier is armed before `body` runs, because a scripted release can
  /// resume and publish before the caller would otherwise be suspended, and it
  /// is fired on both branches of the epilogue, a refused stale result is a
  /// completed decision.
  ///
  /// - Parameter body: The release that will produce the result.
  public func settlingOneAsyncResult(_ body: () async throws -> Void) async throws {
    let signal = StorefrontCompletionSignal()
    armedCompletionSignal = signal
    try await body()
    try await signal.wait()
  }

  /// Returns immediately: this port releases nothing.
  ///
  /// No derived value survives the call that computed it and every accepted
  /// response is kept for the session, so there is no lifetime decision to make
  /// and no clock to advance. The declaration says so,
  /// ``StorefrontRuntimeSemantics/releasesUnobservedValues`` is `false`, and
  /// the teardown phase records an explicit skip rather than passing its release
  /// proof for the wrong reason.
  ///
  /// - Parameter duration: Ignored.
  public func settlingLifetimeRelease(advancingBy duration: Duration) async throws {}

  // MARK: - Transactions and rendering

  /// Applies one transaction's writes and settles it.
  ///
  /// A write taken from inside a render, the account observer writing the
  /// shopper it just accepted, applies without settling again, so one user
  /// action stays one render however many observers participate in it.
  ///
  /// - Parameter body: The writes this transaction owns.
  private func mutate(_ body: () -> Void) {
    body()
    guard !isRendering else { return }
    render()
  }

  /// Runs every held observer once and reconciles what they asked for.
  ///
  /// The observers run inside one `withObservationTracking` scope with an empty
  /// change callback. The scope is not how this port decides to render, see
  /// the type's disclosed deviations, but it keeps the registrar's
  /// registration and notification costs in the sample, which is what makes
  /// this a measurement of raw Observation rather than of a hand-rolled
  /// invalidation graph wearing its name.
  func render() {
    isRendering = true
    isCollectingDemand = true
    pendingDemand.removeAll(keepingCapacity: true)
    pendingGuards.removeAll(keepingCapacity: true)
    withObservationTracking {
      // The account observer runs first, matching the Cog mechanism. It writes
      // the accepted shopper before later observers price this render.
      if holds.contains(.account) { renderAccount() }
      if holds.contains(.browse) { renderBrowse() }
      if holds.contains(.search) { renderSearch() }
      if holds.contains(.cart) { renderCart() }
      if holds.contains(.detail) { renderDetail() }
    } onChange: {
    }
    isCollectingDemand = false
    reconcileAsyncDemand()
    isRendering = false
  }

  /// Accepts the account response into the signed-in-shopper source.
  private func renderAccount() {
    let account = accountValue()
    sink.recordAccount()
    signIn(as: account)
  }

  /// Renders the visible rows and demands the prefetch margin.
  ///
  /// The funnel runs twice here, once for each of the two windows, because
  /// neither call can know the other happened. Reading the prefetch margin's
  /// rows is what starts their inventory and offer requests; a list that
  /// demanded only what is on screen would show a price arriving one frame after
  /// the row it belongs to.
  private func renderBrowse() {
    let visibleProductIDs = visibleProductIDs()
    var checksum = 0
    for id in visibleProductIDs {
      let productRow = productRow(of: id)
      checksum = StorefrontKernels.mix(checksum, id.raw)
      checksum = StorefrontKernels.mix(checksum, productRow.priceCents)
      checksum = StorefrontKernels.mix(checksum, productRow.availableUnits)
      checksum = StorefrontKernels.mix(checksum, productRow.badges.rawValue)
      checksum = StorefrontKernels.mix(checksum, productRow.cartQuantity)
    }
    let prefetchProductIDs = prefetchProductIDs()
    for id in prefetchProductIDs {
      _ = productRow(of: id)
    }
    sink.recordBrowse(
      visible: visibleProductIDs,
      demanded: prefetchProductIDs,
      checksum: checksum
    )
  }

  /// Renders the search field's suggestions.
  private func renderSearch() {
    sink.recordSearch(suggestions: suggestionsValue())
  }

  /// Renders the cart's money and readiness.
  private func renderCart() {
    let orderTotal = orderTotal()
    let checkoutReadiness = checkoutReadiness()
    sink.recordCart(total: orderTotal, readiness: checkoutReadiness)
  }

  /// Renders the open product's detail payload and the recommendation shelf.
  ///
  /// Reading nothing else when no product is open is what makes the detail
  /// payload and the recommendation shelf undemanded, which, in a port with a
  /// lifetime model, is what would let them be released.
  private func renderDetail() {
    guard let selectedProduct = model.selectedProduct else {
      sink.recordDetail(reviewCount: 0, recommendations: [])
      return
    }
    let detail = detailValue(for: selectedProduct)
    let recommendations = recommendationsValue()
    sink.recordDetail(
      reviewCount: detail.reviewCount,
      recommendations: recommendations
    )
  }

  nonisolated deinit {}
}
