extension StorefrontSessionDriver {
  /// Runs the whole standard interaction trace.
  ///
  /// Every step is a named domain verb and every suspension is a definite
  /// signal, so this method finishes in bounded time or fails, it never waits
  /// on a duration and never polls.
  public func runStandardTrace() async throws {
    try await runBootstrapPhase()
    try await runRootDataPhase()
    try await runInitialRowDataPhase()
    try await runScrollPhase()
    try await runSearchPhase()
    try await runFilterPhase()
    try await runCartPhase()
    try await runDetailPhase()
    try await runCheckoutPhase()
    try await runBurstPhase()
    try await runTeardownPhase()
  }

  /// The subset a cold-start measurement covers: bootstrap through the first
  /// complete screen.
  public func runColdStart() async throws {
    try await runBootstrapPhase()
    try await runRootDataPhase()
    try await runInitialRowDataPhase()
  }

  // MARK: - 1. Bootstrap

  /// Bootstrap has happened in `init`; this phase checks the loading shell.
  ///
  /// The claim is that a storefront with no data yet is *cheap*: the browse
  /// observer ran the number of times registration alone accounts for, found
  /// nothing on screen, and started exactly three requests. A runtime that
  /// eagerly demanded per-row work before it had rows would fail here rather
  /// than merely being slower.
  ///
  /// Three, not two, and the third is worth naming: the search index is
  /// demanded as soon as anything asks which products match the (empty) query,
  /// so it is requested over an empty catalog and then superseded the moment a
  /// real catalog lands. That is lazy demand behaving correctly rather than a
  /// defect, the index's *selector* depends on the catalog, so it must run to
  /// find that out, and the release order below accepts both generations in
  /// turn rather than pretending only one exists.
  public func runBootstrapPhase() async throws {
    let phase = StorefrontPhase.bootstrap.rawValue
    check(phase: phase, "visible rows", expected: 0, actual: sink.visibleProductIDs.count)
    // Registration settles the shell from nothing to an empty list. Each
    // runtime declares the run count for that change.
    check(
      phase: phase,
      "browse runs",
      expected: semantics.browseRunsPerContentChangingTurn,
      actual: sink.browseRuns
    )
    await awaitStarted([.catalog, .account, .searchIndex])
    if recordsCheckpoints {
      let started: [StorefrontRequestID] = await script.startedRequests
      let names = started.map { $0.description }.sorted()
      check(
        phase: phase,
        "root requests",
        expected: "[account, catalog, searchIndex]",
        actual: "[\(names.joined(separator: ", "))]"
      )
    }
  }

  // MARK: - 2. Root data

  /// Accepts the account and then the catalog, and materializes the first
  /// viewport.
  ///
  /// The release order is load-bearing and deliberately not the start order.
  /// The account lands **first** so the shopper exists before any row does; a
  /// row materialized while signed out would request an offer, get none, and
  /// then request it again after sign-in, real duplicate work that this
  /// ordering avoids and that the no-duplicate-work checkpoint would catch.
  public func runRootDataPhase() async throws {
    let phase = StorefrontPhase.rootData.rawValue
    try await release(.account)
    world.isSignedIn = true
    // Two runs for Cog, and both are real: registration fires the account
    // observer against the resting `nil`, and the accepted account fires it
    // again. An observer that only fired on change would leave the signed-out
    // world unwritten. Read from the declaration rather than written as a
    // literal, because a runtime whose observers register differently owes a
    // different number here and is not wrong for it.
    check(
      phase: phase,
      "account runs",
      expected: semantics.accountRunsThroughSignIn,
      actual: sink.accountRuns
    )

    // Accept the empty-catalog index while it is current. After the catalog
    // lands, accept its replacement. This resolves both requests by name.
    try await release(.searchIndex)
    try await release(.catalog)
    await awaitStarted([.searchIndex, .searchIndex])
    try await release(.searchIndex)

    check(
      phase: phase,
      "visible ids",
      expected: describe(world.visibleProductIDs),
      actual: describe(sink.visibleProductIDs)
    )
    check(
      phase: phase,
      "visible row count",
      expected: profile.viewportRowCount,
      actual: sink.visibleProductIDs.count
    )
    recordVisited(sink.visibleProductIDs)
  }

  // MARK: - 3. Initial row data

  /// Resolves the first viewport's inventory and offers, newest request first.
  ///
  /// Newest-first is the deliberate out-of-order rule. Once they have all
  /// landed the rendered content must match the shadow model exactly, which is
  /// the first point in the trace where the sixteen-stage pricing ladder, live
  /// inventory, and personalized offers have all contributed.
  public func runInitialRowDataPhase() async throws {
    let phase = StorefrontPhase.initialRowData.rawValue
    await awaitRowRequests()
    let released = try await drainRequests()
    check(
      phase: phase,
      "released row requests",
      expected: expectedPrefetchRequestCount(),
      actual: released
    )
    check(
      phase: phase,
      "visible checksum",
      expected: world.visibleChecksum,
      actual: sink.visibleChecksum
    )
    if recordsCheckpoints {
      let inventoryRequestsAreUnique = await inventoryRequestsAreUnique()
      check(
        phase: phase,
        "no duplicate inventory work",
        expected: true,
        actual: inventoryRequestsAreUnique
      )
    }
  }

  // MARK: - 4. Scroll

  /// Scrolls through the session's distinct rows, down and partly back up.
  public func runScrollPhase() async throws {
    let phase = StorefrontPhase.scroll.rawValue
    for window in StorefrontSession.scrollPlan(for: profile) {
      runtime.scrollRows(to: window)
      world.window = window
      await awaitRowRequests()
      try await drainRequests()
      recordVisited(sink.visibleProductIDs)
    }

    check(
      phase: phase,
      "reached the visit target",
      expected: true,
      actual: visitedProductIDs.count >= profile.visitedRowCount
    )
    check(
      phase: phase,
      "visible checksum",
      expected: world.visibleChecksum,
      actual: sink.visibleChecksum
    )
    if recordsCheckpoints {
      let inventoryRequestsAreUnique = await inventoryRequestsAreUnique()
      check(
        phase: phase,
        "no duplicate inventory work",
        expected: true,
        actual: inventoryRequestsAreUnique
      )
    }
  }

  // MARK: - 5. Search

  /// Types the query one character per domain operation, completes a stale
  /// generation on purpose, and accepts only the current one.
  public func runSearchPhase() async throws {
    let phase = StorefrontPhase.search.rawValue
    let queries = StorefrontSession.distinctNormalizedQueries
    guard let finalQuery = queries.last, queries.count >= 2 else { return }
    let staleQuery = queries[queries.count - 2]

    var suggestionStarts = 0
    var previousNormalized = ""
    for prefix in StorefrontSession.searchPrefixes {
      runtime.typeSearchQuery(prefix)
      world.query = prefix
      let normalized = StorefrontKernels.normalize(prefix)
      // A keystroke that normalizes to what was already there costs a turn and
      // starts no request at all. That is the equality gate on the normalized
      // query doing its job, and it is why the generation count below is
      // smaller than the keystroke count.
      guard !normalized.isEmpty, normalized != previousNormalized else {
        try await drainRowRequests()
        continue
      }
      previousNormalized = normalized
      await awaitStarted([.suggestions(query: normalized)])
      suggestionStarts += 1
      // Everything except the last two generations is released as it goes, so
      // the phase never has more than one superseded request in flight and the
      // stale step below is the only stale step.
      if normalized != staleQuery && normalized != finalQuery {
        try await release(.suggestions(query: normalized))
      }
      try await drainRowRequests()
    }

    check(
      phase: phase,
      "suggestion generations started",
      expected: queries.count,
      actual: suggestionStarts
    )
    check(
      phase: phase,
      "equal normalizations start no generation",
      expected: true,
      actual: suggestionStarts < StorefrontSession.searchPrefixes.count
    )

    let acceptedBeforeStale = recordsCheckpoints ? sink.suggestions : []
    // The stale generation completes *after* it was superseded. The runtime must refuse
    // it: cancellation is advisory, and correctness comes from the generation
    // check rather than from old work cooperating.
    try await release(.suggestions(query: staleQuery))
    check(
      phase: phase,
      "stale generation refused",
      expected: describeStrings(acceptedBeforeStale),
      actual: describeStrings(sink.suggestions)
    )

    try await release(.suggestions(query: finalQuery))
    check(
      phase: phase,
      "current generation accepted",
      expected: describeStrings(
        StorefrontKernels.suggestions(
          for: finalQuery,
          products: catalog.products,
          count: profile.suggestionCount
        )
      ),
      actual: describeStrings(sink.suggestions)
    )
    try await drainRequests()

    check(
      phase: phase,
      "visible ids after search",
      expected: describe(world.visibleProductIDs),
      actual: describe(sink.visibleProductIDs)
    )
    recordVisited(sink.visibleProductIDs)
  }

  // MARK: - 6. Filters

  /// Toggles stock, category, and sort, and checks each is exactly one turn.
  ///
  /// The first verb changes four sources in one transaction. The browse observer
  /// must run only the declared count for that transaction. A port that performed
  /// ``StorefrontRuntime/applyBrowseFilters(category:sortMode:inStockOnly:)``
  /// as separate writes would run three or four times and render unwanted
  /// screens. The protocol hides those sources, so this checkpoint detects the
  /// mistake through the run count.
  public func runFilterPhase() async throws {
    let phase = StorefrontPhase.filters.rawValue
    // Filter to a category the shopper can actually see a chip for. Picking a
    // category by ordinal would sometimes select one the current search results
    // do not contain, and an empty list is a filter test that proves nothing.
    let category =
      sink.visibleProductIDs.first.flatMap { world.productIndex[$0]?.category }
      ?? CategoryID(0)

    var before = sink.browseRuns
    runtime.applyBrowseFilters(category: category, sortMode: .priceAscending, inStockOnly: true)
    world.category = category
    world.sortMode = .priceAscending
    world.inStockOnly = true
    world.window = RowWindow(offset: 0, length: world.window.length)
    check(
      phase: phase,
      "multi-source filter is one browse run",
      expected: semantics.browseRunsPerContentChangingTurn,
      actual: sink.browseRuns - before
    )
    try await drainRequests()
    check(
      phase: phase,
      "filtered visible ids",
      expected: describe(world.visibleProductIDs),
      actual: describe(sink.visibleProductIDs)
    )

    // Reversing the price order is guaranteed to reorder the list, so this
    // measures one turn's propagation rather than one turn's equality gate.
    before = sink.browseRuns
    runtime.selectSortMode(.priceDescending)
    world.sortMode = .priceDescending
    check(
      phase: phase,
      "reordering sort change is one browse run",
      expected: semantics.browseRunsPerContentChangingTurn,
      actual: sink.browseRuns - before
    )

    // Selecting the sort that is already selected is the other half of the
    // claim: an equal write settles and, for a runtime with an equality gate on
    // its sources, renders nothing. A runtime without one owes its own number
    // here and declares it rather than being held to Cog's.
    before = sink.browseRuns
    runtime.selectSortMode(.priceDescending)
    check(
      phase: phase,
      "redundant sort change renders nothing",
      expected: semantics.browseRunsPerEqualWrite,
      actual: sink.browseRuns - before
    )

    runtime.selectSortMode(.relevance)
    world.sortMode = .relevance
    runtime.setInStockOnly(false)
    world.inStockOnly = false
    runtime.selectCategory(nil)
    world.category = nil
    runtime.typeSearchQuery("")
    world.query = ""
    try await drainRequests()
    check(
      phase: phase,
      "cleared visible ids",
      expected: describe(world.visibleProductIDs),
      actual: describe(sink.visibleProductIDs)
    )
    recordVisited(sink.visibleProductIDs)
  }

  // MARK: - 7. Favorites and cart

  /// Favorites three visible products and adds three products to the cart.
  public func runCartPhase() async throws {
    let phase = StorefrontPhase.cart.rawValue
    let favorites = Array(sink.visibleProductIDs.prefix(3))
    for id in favorites {
      let before = sink.browseRuns
      runtime.toggleFavorite(id)
      world.favorites.insert(id)
      check(
        phase: phase,
        "favoriting \(id) is one browse run",
        expected: semantics.browseRunsPerContentChangingTurn,
        actual: sink.browseRuns - before
      )
    }

    let cartIDs = StorefrontSession.cartProductIDs(for: profile, catalog: catalog)
    for (position, id) in cartIDs.enumerated() {
      runtime.addToCart(id, quantity: position + 1)
      world.cartContents.append(id)
      world.cartQuantities[id] = (world.cartQuantities[id] ?? 0) + position + 1
    }
    // A cart product is usually nowhere near the viewport, so adding one
    // demands a row's worth of work for a product no screen is showing. Those
    // requests must land before the quote identities the shadow computes are
    // the ones the graph asks for, a quote priced from unresolved inventory is
    // a different request, and awaiting the wrong one would hang.
    await awaitRowRequests(for: cartIDs, includeOffers: pricingReadsOffers)
    await awaitRowRequests()
    try await drainRequests()
    await awaitQuoteRequests()
    try await drainRequests()

    check(
      phase: phase,
      "cart line count",
      expected: cartIDs.count,
      actual: world.cartLines.count
    )
    check(
      phase: phase,
      "order total",
      expected: describeTotal(world.orderTotal()),
      actual: describeTotal(sink.orderTotal)
    )
  }

  // MARK: - 8. Detail

  /// Opens a product, resolves its detail and the recommendation shelf out of
  /// order, changes a variant, and returns to the list.
  public func runDetailPhase() async throws {
    let phase = StorefrontPhase.detail.rawValue
    guard let id = sink.visibleProductIDs.first else { return }
    guard let product = world.productIndex[id] else { return }

    nextViewRank += 1
    runtime.openProduct(id, rank: nextViewRank)
    world.viewRanks[id] = nextViewRank
    await awaitStarted([.detail(id: id), .recommendations(accountID: world.shopper.accountID)])

    // Recommendations first, detail second, the opposite of the order a
    // detail screen needs them in.
    try await release(.recommendations(accountID: world.shopper.accountID))
    try await release(.detail(id: id))

    check(
      phase: phase,
      "detail review count",
      expected: StorefrontFixtures.detail(for: product).reviewCount,
      actual: sink.detailReviewCount
    )
    check(
      phase: phase,
      "recommendations",
      expected: describe(
        StorefrontKernels.recommend(
          products: catalog.products,
          taste: world.shopper.taste,
          count: profile.recommendationCount
        )
      ),
      actual: describe(sink.recommendations)
    )

    if product.variants.count > 1 {
      runtime.selectVariant(1, for: id)
      world.variants[id] = 1
      try await drainRequests()
      check(
        phase: phase,
        "price after variant change",
        expected: world.effectivePrice(for: id),
        actual: runtime.peekEffectivePrice(of: id)
      )
    }

    runtime.closeProduct()
    try await drainRequests()
  }

  // MARK: - 9. Checkout

  /// Edits quantities rapidly, applies a coupon, and changes shipping.
  ///
  /// Each edit supersedes the in-flight shipping and tax quotes. Because the
  /// script leaves superseded requests suspended, the drain that follows
  /// releases the newest first, so the current generation is accepted and
  /// every stale one is refused afterwards, which is the strongest ordering to
  /// check the generation rule against.
  public func runCheckoutPhase() async throws {
    let phase = StorefrontPhase.checkout.rawValue
    guard let firstLine = world.cartContents.first else { return }

    for quantity in [4, 2, 5] {
      runtime.setCartQuantity(quantity, for: firstLine)
      world.cartQuantities[firstLine] = quantity
    }

    runtime.applyCoupon(StorefrontFixtures.sessionCoupon)
    world.coupon = StorefrontFixtures.sessionCoupon

    runtime.selectShippingMethod(.express)
    world.method = .express

    await awaitRowRequests(for: world.cartContents, includeOffers: pricingReadsOffers)
    await awaitRowRequests()
    await awaitQuoteRequests()
    let releasedQuotes = try await drainRequests()
    // Five mutations, each of which moved the discounted subtotal, so at least
    // the final pair plus one superseded pair must have been outstanding.
    check(
      phase: phase,
      "quote replacement left work to release",
      expected: true,
      actual: releasedQuotes >= 4
    )
    check(
      phase: phase,
      "order total after coupon and shipping",
      expected: describeTotal(world.orderTotal()),
      actual: describeTotal(sink.orderTotal)
    )
    check(
      phase: phase,
      "promotion plan",
      expected: describeStrings(world.promotionPlan.appliedIDs),
      actual: describeStrings(runtime.peekPromotionPlan().appliedIDs)
    )
  }

  // MARK: - 10. Inventory burst

  /// Publishes one inventory burst covering demanded and undemanded products.
  ///
  /// The split is the whole experiment, and the result is sharper than "the
  /// offscreen half re-rendered nothing": the offscreen half **asks the service
  /// for nothing at all**. A row that scrolled out of the prefetch margin is no
  /// longer read by anything, so invalidating its inventory marks it stale and
  /// stops, no selector runs, no request starts, no work happens until
  /// something wants that row again. That is what fine-grained laziness buys a
  /// storefront receiving a warehouse feed it did not ask for, and it is the
  /// single most valuable claim in this trace.
  public func runBurstPhase() async throws {
    let phase = StorefrontPhase.burst.rawValue
    let visible = sink.visibleProductIDs
    let demanded = world.prefetchProductIDs
    let burst = StorefrontSession.inventoryBurstIDs(
      for: profile,
      visible: visible,
      previouslyVisited: visitedProductIDs,
      demanded: demanded
    )
    let halves = StorefrontSession.splitBurst(burst, demanded: demanded)
    guard !halves.onScreen.isEmpty, !halves.offScreen.isEmpty else {
      check(phase: phase, "burst has both halves", expected: true, actual: false)
      return
    }

    let generation = 1
    let runsBeforeTurn = sink.browseRuns
    runtime.publishInventoryBurst(burst, generation: generation)
    for id in burst { world.inventoryGenerations[id] = generation }
    // A generation change makes the reading stale; it does not make it wrong.
    // Value reads keep the last accepted success until a newer one is accepted,
    // so the screen does not flicker back to a resting value on the way.
    check(
      phase: phase,
      "burst turn renders nothing new",
      expected: semantics.browseRunsPerUndemandedInvalidation,
      actual: sink.browseRuns - runsBeforeTurn
    )

    await awaitStarted(
      halves.onScreen.map { .inventory(id: $0, generation: generation) }
    )
    if recordsCheckpoints {
      var undemandedStarts = 0
      for id in halves.offScreen {
        undemandedStarts += await script.startCount(
          of: .inventory(id: id, generation: generation)
        )
      }
      checkUndemandedWork(phase: phase, "undemanded half starts no work", starts: undemandedStarts)
    }

    let runsBeforeOnScreen = sink.browseRuns
    for id in halves.onScreen {
      try await release(.inventory(id: id, generation: generation))
    }
    check(
      phase: phase,
      "demanded half re-renders",
      expected: true,
      actual: sink.browseRuns > runsBeforeOnScreen
    )

    if recordsCheckpoints {
      var undemandedStartsAfter = 0
      for id in halves.offScreen {
        undemandedStartsAfter += await script.startCount(
          of: .inventory(id: id, generation: generation)
        )
      }
      checkUndemandedWork(
        phase: phase,
        "undemanded half still starts no work",
        starts: undemandedStartsAfter
      )
    }

    try await drainRequests()
    check(
      phase: phase,
      "visible checksum after burst",
      expected: world.visibleChecksum,
      actual: sink.visibleChecksum
    )
  }

  /// Publishes one inventory burst over the demanded rows and settles it.
  ///
  /// Extracted from the burst phase so the async-burst benchmark cut can drive
  /// exactly this round trip repeatedly without replaying the ten phases ahead
  /// of it. It is the same turn, the same barrier, the same release order,
  /// and the same graph settlement the trace performs. The benchmark validates
  /// the resulting checksum and demanded set after stopping measurement.
  ///
  /// - Parameter generation: The generation to advance the touched rows to.
  /// - Returns: The products the burst touched.
  @discardableResult
  public func runDemandedInventoryBurst(generation: Int) async throws -> [ProductID] {
    let touched = world.prefetchProductIDs
    guard !touched.isEmpty else { return [] }
    for id in touched { world.inventoryGenerations[id] = generation }
    try await runInventoryBurst(touching: touched, generation: generation)
    return touched
  }

  /// Publishes and settles one already-chosen inventory burst.
  ///
  /// The benchmark snapshots the demanded product identifiers before starting
  /// its timer and calls this method inside it. Choosing those identifiers and
  /// updating its shadow therefore remain verifier work outside the measured
  /// round trip, while the graph turn, async tasks, responses, and reactions
  /// remain inside.
  ///
  /// - Parameters:
  ///   - touched: Products whose inventory generation changes.
  ///   - generation: The generation to publish.
  public func runInventoryBurst(
    touching touched: [ProductID],
    generation: Int
  ) async throws {
    guard !touched.isEmpty else { return }
    runtime.publishInventoryBurst(touched, generation: generation)
    await awaitStarted(touched.map { .inventory(id: $0, generation: generation) })
    try await drainRequests()
  }

  // MARK: - 11. Teardown

  /// Navigates away, proves replacement is a definite signal, and advances the
  /// runtime's own injected clock through lifetime grace to prove release.
  ///
  /// Release is proven by *behavior*, not by a diagnostic: after grace, a row
  /// the session already resolved is demanded again, and the service sees a
  /// second request for the same identity. A state that had survived would have
  /// answered from its cache and started nothing.
  ///
  /// This is the one phase with two optional claims in it. A runtime that hands
  /// back no per-generation refresh handle, or that has no lifetime model at
  /// all, records an explicit skip for the claim it does not make and is held
  /// to everything else in the phase, including "nothing on screen", which no
  /// runtime is exempt from.
  public func runTeardownPhase() async throws {
    let phase = StorefrontPhase.teardown.rawValue

    // Replacement resolves the superseded handle without any clock at all.
    await script.setIgnoresCancellation(false)
    let superseded = runtime.refreshRecommendations()
    runtime.refreshRecommendations()
    if semantics.hasPerGenerationRefreshHandles {
      let supersededOutcome = await superseded.outcome
      check(
        phase: phase,
        "superseded refresh",
        expected: "superseded",
        actual: describeOutcome(supersededOutcome)
      )
    } else {
      // Recorded, not silently absent: awaiting a handle that never resolves on
      // replacement would hang, and greening the claim anyway would be worse
      // than not making it.
      skip(
        phase: phase,
        "superseded refresh",
        because: "this runtime declares no per-generation refresh handle"
      )
    }
    await script.setIgnoresCancellation(true)
    try await drainRequests()

    // Navigate away: nothing is on screen and no product is open.
    let restingRow = sink.visibleProductIDs.first
    runtime.scrollRows(to: RowWindow(offset: 0, length: 0))
    world.window = RowWindow(offset: 0, length: 0)
    runtime.closeProduct()
    try await drainRequests()
    check(phase: phase, "nothing on screen", expected: 0, actual: sink.visibleProductIDs.count)

    guard let restingRow else { return }
    let generation = world.inventoryGenerations[restingRow] ?? 0
    let restingRequest = StorefrontRequestID.inventory(id: restingRow, generation: generation)
    let requestsBefore = await script.startCount(of: restingRequest)

    // Advance past grace on the runtime's own injected clock, and wait for the
    // release decision itself rather than for a duration. The clock belongs to
    // the runtime, not to this trace, which is why this is a barrier rather than
    // a `clock.advance`.
    try await runtime.settlingLifetimeRelease(advancingBy: .seconds(120))

    guard semantics.releasesUnobservedValues else {
      // A runtime with no lifetime model has nothing to release, so the proof
      // below would pass for the wrong reason, the row would be re-requested
      // because it was never cached, not because it was released. Record the
      // skip and stop.
      skip(
        phase: phase,
        "released row asks again",
        because: "this runtime declares no lifetime release for unobserved values"
      )
      try await drainRequests()
      return
    }

    // Re-materialize the same row. A released state has to ask again, and
    // awaiting that second start is what makes this a proof rather than a
    // sample: a state that survived would answer from its cache and this would
    // never be satisfied.
    runtime.scrollRows(to: RowWindow(offset: 0, length: profile.viewportRowCount))
    world.window = RowWindow(offset: 0, length: profile.viewportRowCount)
    await awaitStarted([restingRequest, restingRequest])
    let requestsAfter = await script.startCount(of: restingRequest)
    check(
      phase: phase,
      "released row asks again",
      expected: requestsBefore + 1,
      actual: requestsAfter
    )
    try await drainRequests()
  }

  // MARK: - Helpers

  /// Records which products the session has materialized.
  ///
  /// - Parameter ids: Products now on screen.
  func recordVisited(_ ids: [ProductID]) {
    for id in ids where visitedProductIDSet.insert(id).inserted {
      visitedProductIDs.append(id)
    }
  }

  /// Releases every scheduled or suspended request that is *not* a suggestion.
  ///
  /// The search phase deliberately keeps two suggestion generations in flight,
  /// so its per-keystroke drain must leave them alone while still resolving the
  /// row work each new candidate set demands.
  func drainRowRequests() async throws {
    for _ in 0..<64 {
      let pending = await script.pendingRequestIDs.filter { request in
        if case .suggestions = request { return false }
        return true
      }
      guard !pending.isEmpty else { return }
      for id in pending.reversed() {
        try await release(id)
      }
    }
    fatalError("The Storefront script never ran out of non-suggestion requests to release.")
  }

  /// Waits until every row request the demanded set implies has started.
  ///
  /// This is the barrier that replaces guessing when a `@concurrent` request
  /// task has reached the service. Draining without it can return before the
  /// work has suspended, and the graph then looks like it settled without ever
  /// asking, which is the difference between a benchmark and a coin flip.
  func awaitRowRequests() async {
    await awaitRowRequests(for: world.prefetchProductIDs)
  }

  /// Waits until the row requests for `ids` have started.
  ///
  /// Whether an *offer* is among them depends on who is reading. A row on
  /// screen always demands one, because its badges do. A cart line demands one
  /// only when the profile's policy prefix reaches the personalized-offer
  /// stage, the smoke profile's four-policy ladder stops well before it, so
  /// awaiting an offer for a cart product there would be waiting for a request
  /// the graph is correct never to make.
  ///
  /// - Parameters:
  ///   - ids: The products whose row work must be in flight.
  ///   - includeOffers: Whether an offer request is expected for each.
  func awaitRowRequests(for ids: [ProductID], includeOffers: Bool = true) async {
    var wanted: [StorefrontRequestID] = []
    for id in ids {
      wanted.append(.inventory(id: id, generation: world.inventoryGenerations[id] ?? 0))
      if includeOffers { wanted.append(.offer(id: id)) }
    }
    guard !wanted.isEmpty else { return }
    await awaitStarted(wanted)
  }

  /// Whether this profile's pricing ladder reads the personalized offer.
  ///
  /// Derived from the profile rather than observed, so a profile that shortens
  /// or lengthens its ladder changes what the trace waits for automatically.
  var pricingReadsOffers: Bool {
    StorefrontPricing.ladder
      .prefix(profile.pricingPolicyCount)
      .contains(.personalizedOffer)
  }

  /// Waits until the shipping and tax quotes for the current cart have started.
  ///
  /// The identities are computed from the shadow model, so this both waits for
  /// the right requests and asserts, by hanging loudly rather than passing
  /// quietly, that the graph asked for the quote the cart implies.
  func awaitQuoteRequests() async {
    guard !world.cartLines.isEmpty else { return }
    let total = world.orderTotal()
    await awaitStarted([
      .shippingQuote(
        subtotalCents: total.discountedSubtotalCents,
        market: world.address.market,
        method: world.method
      ),
      .taxQuote(subtotalCents: total.discountedSubtotalCents, market: world.address.market),
    ])
  }

  /// How many row requests the first viewport should produce.
  ///
  /// Derived: every prefetched product asks for inventory once and an offer
  /// once, and the prefetch set is the window widened by the profile's margin
  /// on each side, clamped to the list.
  func expectedPrefetchRequestCount() -> Int {
    let flattened = world.flattenedSectionOrder
    let start = max(0, world.window.offset - profile.prefetchMargin)
    let end = min(
      flattened.count,
      world.window.offset + world.window.length + profile.prefetchMargin
    )
    return max(0, end - start) * 2
  }

  /// Whether every inventory request identity has started exactly once.
  func inventoryRequestsAreUnique() async -> Bool {
    let started = await script.startedRequests
    var seen: Set<StorefrontRequestID> = []
    for request in started {
      guard case .inventory = request else { continue }
      guard seen.insert(request).inserted else { return false }
    }
    return true
  }

  /// Asserts how much service work an undemanded invalidation started.
  ///
  /// Shared by the burst phase's two identical claims, before and after the
  /// demanded half is released, so the two cannot drift apart. The expectation
  /// is always ``StorefrontRuntimeSemantics/declaredUndemandedRequestStarts``,
  /// and this helper deliberately has no skip branch: "offscreen updates do no
  /// visible work" is the sharpest claim the macrobenchmark makes, and letting a
  /// runtime opt out of it would record a holding checkpoint for a claim nobody
  /// ever checked. A runtime that does start offscreen work states how much and
  /// is failed when it starts a different amount, which is a legible number for
  /// the results table rather than a silent absence.
  ///
  /// - Parameters:
  ///   - phase: Which phase is claiming it.
  ///   - name: What is being claimed.
  ///   - starts: How many requests the offscreen half actually started.
  func checkUndemandedWork(phase: String, _ name: String, starts: Int) {
    check(
      phase: phase,
      name,
      expected: semantics.declaredUndemandedRequestStarts,
      actual: starts
    )
  }

  /// Renders identifiers for a checkpoint.
  func describe(_ ids: [ProductID]) -> String {
    "[\(ids.map(\.description).joined(separator: ","))]"
  }

  /// Renders strings for a checkpoint.
  func describeStrings(_ values: [String]) -> String {
    "[\(values.joined(separator: ","))]"
  }

  /// Renders money for a checkpoint.
  func describeTotal(_ total: OrderTotal) -> String {
    "subtotal=\(total.subtotalCents) discount=\(total.discountCents) "
      + "tax=\(total.taxCents) shipping=\(total.shippingCents) total=\(total.totalCents)"
  }

  /// Renders a refresh outcome for a checkpoint.
  ///
  /// One word, never a payload, so four runtimes producing four different
  /// recommendation lists still agree that the demand was superseded.
  func describeOutcome(_ outcome: StorefrontRefreshOutcome<[ProductID]>) -> String {
    outcome.checkpointDescription
  }
}
