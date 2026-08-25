internal import Observation
internal import StorefrontWorkload

// Every derived value this port computes, and the caches that stop it
// recomputing them.
//
// The shape mirrors the Cog port's declarations one for one — the same funnel,
// the same kernels, the same arguments — so that the two runtimes compute the
// same session rather than two similar ones. What differs is *where the answers
// are kept*: Cog keeps fifty-three of them and knows exactly which to discard,
// while this port keeps seven and discards each by hand.
//
// A builder here follows one rule: return the cache if it is there, otherwise
// rebuild the whole thing and store it. Nothing partially rebuilds, because
// partial rebuilding is dependency tracking wearing a different hat.

extension MemoObservationStorefrontRuntime {
  // MARK: - Catalog

  /// The accepted catalog, indexed.
  ///
  /// - Returns: The cached index, rebuilding it on a miss.
  func catalogIndexCache() -> MemoObservationCatalogIndexCache {
    if let catalogIndex { return catalogIndex }
    let snapshot = catalogCell.value
    let built = MemoObservationCatalogIndexCache(
      products: snapshot.products,
      categories: snapshot.categories,
      productIndex: Dictionary(uniqueKeysWithValues: snapshot.products.map { ($0.id, $0) }),
      categoryNames: Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0.name) })
    )
    catalogIndex = built
    return built
  }

  // MARK: - The search funnel

  /// Whether one product survives the filter bar.
  ///
  /// Mirrors the shadow model's normative definition, including its deliberate
  /// choice to consult the catalog's recorded stock rather than live inventory:
  /// a filter that read live inventory would demand an inventory request for
  /// every product in the catalog the moment the shopper flipped a switch.
  ///
  /// - Parameter product: The product to test.
  /// - Returns: Whether it survives.
  func isEligible(_ product: Product) -> Bool {
    if let category = model.selectedCategory, product.category != category { return false }
    guard model.inStockOnly else { return true }
    return product.variants.contains { $0.catalogStock > 0 }
  }

  /// The whole browse funnel, from the raw query to the sections.
  ///
  /// - Returns: The cached funnel, rebuilding all of it on a miss.
  func searchPipelineCache() -> MemoObservationSearchPipelineCache {
    if let searchPipeline { return searchPipeline }
    let catalog = catalogIndexCache()
    let normalizedQuery = StorefrontKernels.normalize(model.searchQuery)
    let tokens = StorefrontKernels.tokenize(normalizedQuery)
    let candidateIDs = StorefrontKernels.candidates(
      in: searchIndexCell.value,
      tokens: tokens,
      productCount: catalog.products.count
    ).map { ProductID($0) }

    var eligibleIDs: [ProductID] = []
    var scores: [Int: Int] = [:]
    var prices: [Int: Int] = [:]
    eligibleIDs.reserveCapacity(candidateIDs.count)
    for id in candidateIDs {
      guard let product = catalog.productIndex[id], isEligible(product) else { continue }
      eligibleIDs.append(id)
      // Ranking prices are the catalog's list prices, never the ladder's
      // effective ones: sorting a thousand products by a personalized price
      // would demand an offer and a live reading for every one of them, and no
      // storefront does that to order a list.
      scores[id.raw] = StorefrontKernels.relevanceScore(product: product, tokens: tokens)
      prices[id.raw] = product.listPriceCents
    }

    let rankedIDs = StorefrontKernels.rank(
      candidates: eligibleIDs.map(\.raw),
      products: catalog.products,
      scores: scores,
      prices: prices,
      mode: model.sortMode
    )
    let built = MemoObservationSearchPipelineCache(
      normalizedQuery: normalizedQuery,
      tokens: tokens,
      candidateIDs: candidateIDs,
      eligibleIDs: eligibleIDs,
      rankedIDs: rankedIDs,
      sections: sections(from: rankedIDs, catalog: catalog)
    )
    searchPipeline = built
    return built
  }

  /// Groups the ranked products the way the browse list renders them.
  ///
  /// A cross-category best-match band of at most twelve, then the remainder
  /// grouped by category in the order the ranking first met them.
  ///
  /// - Parameters:
  ///   - rankedIDs: The ranked products, best first.
  ///   - catalog: The indexed catalog to look categories up in.
  /// - Returns: The sections, in presentation order.
  private func sections(
    from rankedIDs: [ProductID],
    catalog: MemoObservationCatalogIndexCache
  ) -> [StorefrontSection] {
    let topBandCount = min(rankedIDs.count, 12)
    var sections: [StorefrontSection] = []
    if topBandCount > 0 {
      sections.append(
        StorefrontSection(
          category: nil,
          title: "Best matches",
          productIDs: Array(rankedIDs.prefix(topBandCount))
        )
      )
    }
    var order: [CategoryID] = []
    var grouped: [CategoryID: [ProductID]] = [:]
    for id in rankedIDs.dropFirst(topBandCount) {
      guard let product = catalog.productIndex[id] else { continue }
      if grouped[product.category] == nil { order.append(product.category) }
      grouped[product.category, default: []].append(id)
    }
    for category in order {
      sections.append(
        StorefrontSection(
          category: category,
          title: catalog.categoryNames[category] ?? "Category \(category.raw)",
          productIDs: grouped[category] ?? []
        )
      )
    }
    return sections
  }

  /// What the list has materialized, given the funnel and the row window.
  ///
  /// - Returns: The cached window, rebuilding it on a miss.
  func windowCache() -> MemoObservationWindowCache {
    if let window { return window }
    let flattened = searchPipelineCache().sections.flatMap(\.productIDs)
    let rowWindow = model.rowWindow

    var visibleIDs: [ProductID] = []
    if rowWindow.length > 0, rowWindow.offset < flattened.count {
      let end = min(flattened.count, rowWindow.offset + rowWindow.length)
      visibleIDs = Array(flattened[rowWindow.offset..<end])
    }

    var prefetchIDs: [ProductID] = []
    if rowWindow.length > 0, !flattened.isEmpty {
      let margin = profile.prefetchMargin
      let start = max(0, rowWindow.offset - margin)
      let end = min(flattened.count, rowWindow.offset + rowWindow.length + margin)
      if start < end { prefetchIDs = Array(flattened[start..<end]) }
    }

    let built = MemoObservationWindowCache(
      flattened: flattened,
      visibleIDs: visibleIDs,
      prefetchIDs: prefetchIDs,
      demandedIDs: Set(prefetchIDs)
    )
    window = built
    return built
  }

  // MARK: - Pricing

  /// The shopper the pricing ladder is evaluated for.
  ///
  /// A synthetic guest before the account response is accepted, matching the
  /// shadow model: the tier and the loyalty balance are the only two fields any
  /// policy reads, and pricing a whole catalog as a member before the account
  /// has landed would be wrong for one settlement in a way a checkpoint would
  /// catch.
  var pricingShopper: Shopper {
    if let shopper = model.signedInShopper { return shopper }
    return Shopper(
      accountID: 0,
      name: "",
      tier: .guest,
      taste: StorefrontFeatureVector(0, 0, 0, 0, 0, 0, 0, 0),
      loyaltyPoints: 0
    )
  }

  /// One product's selected variant, clamped to what the product offers.
  ///
  /// - Parameter product: The product being priced.
  /// - Returns: A valid variant index.
  func variantIndex(for product: Product) -> Int {
    let requested = model.selectedVariants[product.id] ?? 0
    return min(max(0, requested), max(0, product.variants.count - 1))
  }

  /// One product's effective price, from the cache when there is an entry.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  func effectivePrice(of id: ProductID) -> Int {
    if let cached = pricing[id] { return cached }
    let computed = computeEffectivePrice(of: id)
    pricing[id] = computed
    return computed
  }

  /// Runs one product's whole pricing ladder, without touching the cache.
  ///
  /// The single most important granularity decision in this port lives on this
  /// line: the ladder is one call, so the cache above is one cell per product
  /// rather than one per policy per price book. The stress profile's three price
  /// books are handled inside the same call, which takes the best qualifying
  /// book in one pass.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  func computeEffectivePrice(of id: ProductID) -> Int {
    let catalog = catalogIndexCache()
    guard let product = catalog.productIndex[id] else { return 0 }
    return StorefrontPricing.effectivePriceWithoutGraph(
      product: product,
      variantIndex: variantIndex(for: product),
      profile: profile,
      shopper: pricingShopper,
      address: model.shippingAddress,
      inventory: inventoryCells[id]?.value ?? .unknown,
      offer: offerCells[id]?.value ?? .none,
      coupon: model.coupon,
      cartQuantity: model.cartQuantities[id] ?? 0,
      viewRank: model.recentlyViewedRanks[id] ?? 0,
      method: model.shippingMethod
    )
  }

  // MARK: - Rows

  /// Units available for one product's selected variant.
  ///
  /// Deliberately unclamped, exactly like the Cog port's availability
  /// declaration: an out-of-range variant reads as zero units rather than as the
  /// last variant's stock.
  ///
  /// - Parameter id: Which product.
  /// - Returns: Units on hand.
  func availability(of id: ProductID) -> Int {
    let reading = inventoryCells[id]?.value ?? .unknown
    return reading.units(forVariant: model.selectedVariants[id] ?? 0)
  }

  /// The badges one product's row shows.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - product: That product's catalog entry.
  /// - Returns: The badges.
  private func badges(for id: ProductID, product: Product) -> ProductBadges {
    var badges: ProductBadges = []
    if effectivePrice(of: id) < product.listPriceCents { badges.insert(.onSale) }
    let units = availability(of: id)
    let reading = inventoryCells[id]?.value ?? .unknown
    if units == 0 && !reading.restockable {
      badges.insert(.soldOut)
    } else if units > 0 && units <= 3 {
      badges.insert(.lowStock)
    }
    if (offerCells[id]?.value ?? .none).discountBasisPoints > 0 { badges.insert(.offer) }
    if model.favorites[id] == true { badges.insert(.favorite) }
    if (model.recentlyViewedRanks[id] ?? 0) > 0 { badges.insert(.recentlyViewed) }
    if (model.cartQuantities[id] ?? 0) > 0 { badges.insert(.inCart) }
    return badges
  }

  /// Everything one product row renders, from the cache when there is an entry.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The row.
  func productRow(for id: ProductID) -> ProductRow {
    if let cached = rows[id] { return cached }
    let catalog = catalogIndexCache()
    guard let product = catalog.productIndex[id] else {
      return ProductRow(
        productID: id,
        name: "",
        categoryName: "",
        priceCents: 0,
        listPriceCents: 0,
        availableUnits: 0,
        badges: [],
        cartQuantity: 0
      )
    }
    let row = ProductRow(
      productID: id,
      name: product.name,
      categoryName: catalog.categoryNames[product.category]
        ?? "Category \(product.category.raw)",
      priceCents: effectivePrice(of: id),
      listPriceCents: product.listPriceCents,
      availableUnits: availability(of: id),
      badges: badges(for: id, product: product),
      cartQuantity: model.cartQuantities[id] ?? 0
    )
    rows[id] = row
    return row
  }

  // MARK: - Cart

  /// The cart's expensive half, from the cache when there is one.
  ///
  /// - Returns: The cached cart, rebuilding it on a miss.
  func cartCache() -> MemoObservationCartCache {
    if let cart { return cart }
    let built = computeCartCache()
    cart = built
    return built
  }

  /// Rebuilds the cart's lines, subtotal, promotion plan, and discounted
  /// subtotal, without touching the cache.
  ///
  /// - Returns: A freshly computed cart.
  func computeCartCache() -> MemoObservationCartCache {
    let catalog = catalogIndexCache()
    let lineIDs = model.cartContents.filter { id in
      guard catalog.productIndex[id] != nil else { return false }
      return (model.cartQuantities[id] ?? 0) > 0
    }
    let lines = lineIDs.map { cartLine(for: $0, catalog: catalog) }
    let subtotalCents = lines.reduce(0) { $0 + $1.extendedCents }
    var promotionPlan = PromotionPlan.none
    if !lines.isEmpty {
      // The bounded dynamic-programming pass, run synchronously because a
      // shopper who types a coupon expects the total to move on the same frame.
      promotionPlan = StorefrontKernels.selectPromotions(
        lines: lines,
        promotions: StorefrontFixtures.promotions(for: profile),
        categories: catalog.productIndex.mapValues(\.category),
        couponID: model.coupon?.raw
      )
    }
    return MemoObservationCartCache(
      lineIDs: lineIDs,
      lines: lines,
      subtotalCents: subtotalCents,
      promotionPlan: promotionPlan,
      discountedSubtotalCents: max(0, subtotalCents - promotionPlan.discountCents)
    )
  }

  /// One cart line.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - catalog: The indexed catalog.
  /// - Returns: The line.
  private func cartLine(
    for id: ProductID,
    catalog: MemoObservationCatalogIndexCache
  ) -> CartLine {
    let quantity = model.cartQuantities[id] ?? 0
    let variant = model.selectedVariants[id] ?? 0
    guard let product = catalog.productIndex[id] else {
      return CartLine(
        productID: id,
        name: "",
        variantIndex: variant,
        quantity: quantity,
        unitPriceCents: 0,
        inStock: false
      )
    }
    return CartLine(
      productID: id,
      name: product.name,
      variantIndex: variant,
      quantity: quantity,
      unitPriceCents: effectivePrice(of: id),
      inStock: availability(of: id) >= quantity
    )
  }

  /// The cart's money, given a settled cart and the accepted quotes.
  ///
  /// Recomputed per cart render rather than cached; see
  /// ``MemoObservationCartCache``.
  ///
  /// - Parameter cart: The settled cart.
  /// - Returns: The order total.
  private func orderTotal(from cart: MemoObservationCartCache) -> OrderTotal {
    OrderTotal(
      subtotalCents: cart.subtotalCents,
      discountCents: cart.promotionPlan.discountCents,
      discountedSubtotalCents: cart.discountedSubtotalCents,
      taxCents: taxQuoteCell.value.taxCents,
      shippingCents: shippingQuoteCell.value.costCents
    )
  }

  /// Whether the cart can be checked out, and why not when it cannot.
  ///
  /// - Parameter cart: The settled cart.
  /// - Returns: The readiness.
  private func checkoutReadiness(from cart: MemoObservationCartCache) -> CheckoutReadiness {
    var blockers: [String] = []
    if cart.lines.isEmpty { blockers.append("The cart is empty.") }
    if cart.lines.contains(where: { !$0.inStock }) {
      blockers.append("Some items are not available in the quantity requested.")
    }
    if model.signedInShopper == nil { blockers.append("Sign in to check out.") }
    if shippingQuoteCell.value.estimatedDays == 0 {
      blockers.append("Waiting for a shipping quote.")
    }
    return CheckoutReadiness(isReady: blockers.isEmpty, blockers: blockers)
  }

  // MARK: - Rendering

  /// Runs every held observer that owes a run, and no others.
  ///
  /// The dirty flags are cleared before each body runs rather than after, so a
  /// body that somehow invalidated its own inputs would owe another run instead
  /// of losing one.
  func render() {
    if holds.contains(.browse), browseDirty {
      browseDirty = false
      renderBrowse()
    }
    if holds.contains(.search), searchDirty {
      searchDirty = false
      renderSearch()
    }
    if holds.contains(.cart), cartDirty {
      cartDirty = false
      renderCart()
    }
    if holds.contains(.detail), detailDirty {
      detailDirty = false
      renderDetail()
    }
  }

  /// The browse screen: the visible rows, their digest, and the prefetch margin.
  ///
  /// Wrapped in the same `withObservationTracking` scope a SwiftUI view body
  /// runs under, with an empty change callback. The empty callback is
  /// deliberate — this port's invalidation is the hand-written scheme, not
  /// Observation — but the registration itself is real work an `@Observable`
  /// application pays on every render, and a comparison that skipped it would be
  /// reporting a cheaper runtime than anyone could actually ship.
  private func renderBrowse() {
    withObservationTracking {
      let window = windowCache()
      var checksum = 0
      for id in window.visibleIDs {
        let productRow = productRow(for: id)
        checksum = StorefrontKernels.mix(checksum, id.raw)
        checksum = StorefrontKernels.mix(checksum, productRow.priceCents)
        checksum = StorefrontKernels.mix(checksum, productRow.availableUnits)
        checksum = StorefrontKernels.mix(checksum, productRow.badges.rawValue)
        checksum = StorefrontKernels.mix(checksum, productRow.cartQuantity)
      }
      // Materializing the prefetch margin is what makes its rows demanded, and
      // therefore what starts their inventory and offer requests at the demand
      // pass. A list that materialized only what is on screen would show a price
      // arriving one frame after the row it belongs to.
      for id in window.prefetchIDs { _ = productRow(for: id) }
      sink.recordBrowse(
        visible: window.visibleIDs,
        demanded: window.prefetchIDs,
        checksum: checksum
      )
    } onChange: {
    }
  }

  /// The search field's suggestions.
  private func renderSearch() {
    withObservationTracking {
      sink.recordSearch(suggestions: suggestionsCell.value)
    } onChange: {
    }
  }

  /// The cart's money and readiness.
  private func renderCart() {
    withObservationTracking {
      let cart = cartCache()
      sink.recordCart(total: orderTotal(from: cart), readiness: checkoutReadiness(from: cart))
    } onChange: {
    }
  }

  /// The open product's detail payload and the recommendation shelf.
  ///
  /// Reading nothing but the selection when no product is open is what lets the
  /// detail payload and the shelf become releasable once the shopper navigates
  /// away and their grace elapses.
  private func renderDetail() {
    withObservationTracking {
      guard let id = model.selectedProduct else {
        sink.recordDetail(reviewCount: 0, recommendations: [])
        return
      }
      sink.recordDetail(
        reviewCount: (detailCells[id]?.value ?? .empty).reviewCount,
        recommendations: recommendationsCell.value
      )
    } onChange: {
    }
  }
}
