import StorefrontWorkload

// Every derived value in the Storefront workload, recomputed from scratch.
//
// Cog's 24 keyless and eight keyed derived declarations appear as plain
// functions. This file has no cache, dirty bit, version, or edge list. Even two
// calls in one render recompute their shared work.
//
// The one thing a function does keep is its own locals. Building the product
// index once inside a call is a local, not a cache. Rebuilding that index for
// each candidate would make the filter quadratic and misstate the raw floor.
// Per-row functions still rebuild what they need on every call.
//
// What each function reads is exactly what its Cog counterpart reads, including
// the two deliberate omissions the Cog declarations document: filter
// eligibility consults the *catalog's* stock rather than live inventory, and
// ranking uses the *list* price rather than the sixteen-stage effective one.
// These choices preserve the workload. Filtering on live inventory would
// request inventory for every catalog product and run a different session.
extension RawObservationStorefrontRuntime {
  // MARK: - Query

  /// The search text, normalized once for everything downstream.
  func normalizedQuery() -> String {
    StorefrontKernels.normalize(model.searchQuery)
  }

  /// The normalized query, split into tokens.
  func queryTokens() -> [String] {
    StorefrontKernels.tokenize(normalizedQuery())
  }

  // MARK: - Catalog views

  /// The accepted catalog's products.
  func catalogProducts() -> [Product] {
    catalogValue().products
  }

  /// The accepted catalog's categories, in identifier order.
  func categories() -> [Category] {
    catalogValue().categories
  }

  /// Products by identifier.
  func productIndex() -> [ProductID: Product] {
    Dictionary(uniqueKeysWithValues: catalogProducts().map { ($0.id, $0) })
  }

  // MARK: - Per-product search state

  /// One product's relevance score for the current query.
  ///
  /// Takes the index and the tokens its caller already has, because the funnel
  /// calls it once per candidate and rebuilding either per candidate would be
  /// quadratic in the catalog. It deliberately does not read this session's
  /// view history, for the reason the Cog declaration records: boosting a
  /// product you just looked at would re-rank the list while you were reading
  /// it.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - productIndex: Products by identifier.
  ///   - tokens: The normalized query's tokens.
  /// - Returns: The relevance score, or zero for an unknown product.
  func searchScore(
    of id: ProductID,
    in productIndex: [ProductID: Product],
    tokens: [String]
  ) -> Int {
    guard let product = productIndex[id] else { return 0 }
    return StorefrontKernels.relevanceScore(product: product, tokens: tokens)
  }

  /// Whether one product survives the filter bar.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - productIndex: Products by identifier.
  /// - Returns: Whether it survives.
  func isFilterEligible(_ id: ProductID, in productIndex: [ProductID: Product]) -> Bool {
    guard let product = productIndex[id] else { return false }
    if let selectedCategory = model.selectedCategory, product.category != selectedCategory {
      return false
    }
    guard model.inStockOnly else { return true }
    return product.variants.contains { $0.catalogStock > 0 }
  }

  // MARK: - The funnel

  /// Products the search index matched, ascending by identifier.
  func searchCandidateIDs() -> [ProductID] {
    let ordinals = StorefrontKernels.candidates(
      in: searchIndexValue(),
      tokens: queryTokens(),
      productCount: catalogProducts().count
    )
    return ordinals.map { ProductID($0) }
  }

  /// Candidates that survive the filter bar.
  func eligibleProductIDs() -> [ProductID] {
    let productIndex = productIndex()
    return searchCandidateIDs().filter { isFilterEligible($0, in: productIndex) }
  }

  /// Eligible products in presentation order.
  func rankedProductIDs() -> [ProductID] {
    let eligibleProductIDs = eligibleProductIDs()
    let productIndex = productIndex()
    let catalogProducts = catalogProducts()
    let tokens = queryTokens()

    var scores: [Int: Int] = [:]
    var prices: [Int: Int] = [:]
    scores.reserveCapacity(eligibleProductIDs.count)
    prices.reserveCapacity(eligibleProductIDs.count)
    for id in eligibleProductIDs {
      scores[id.raw] = searchScore(of: id, in: productIndex, tokens: tokens)
      guard let product = productIndex[id] else { continue }
      prices[id.raw] = product.listPriceCents
    }

    return StorefrontKernels.rank(
      candidates: eligibleProductIDs.map(\.raw),
      products: catalogProducts,
      scores: scores,
      prices: prices,
      mode: model.sortMode
    )
  }

  /// The ranked products, grouped into the sections the browse list renders.
  func sections() -> [StorefrontSection] {
    let rankedProductIDs = rankedProductIDs()
    let productIndex = productIndex()
    let categoryNames = Dictionary(uniqueKeysWithValues: categories().map { ($0.id, $0.name) })

    let topBandCount = min(rankedProductIDs.count, 12)
    var sections: [StorefrontSection] = []
    if topBandCount > 0 {
      sections.append(
        StorefrontSection(
          category: nil,
          title: "Best matches",
          productIDs: Array(rankedProductIDs.prefix(topBandCount))
        )
      )
    }

    var order: [CategoryID] = []
    var grouped: [CategoryID: [ProductID]] = [:]
    for id in rankedProductIDs.dropFirst(topBandCount) {
      guard let product = productIndex[id] else { continue }
      if grouped[product.category] == nil { order.append(product.category) }
      grouped[product.category, default: []].append(id)
    }
    for category in order {
      sections.append(
        StorefrontSection(
          category: category,
          title: categoryNames[category] ?? "Category \(category.raw)",
          productIDs: grouped[category] ?? []
        )
      )
    }
    return sections
  }

  /// The products inside the materialized window, in list order.
  func visibleProductIDs() -> [ProductID] {
    let flattened = sections().flatMap(\.productIDs)
    let rowWindow = model.rowWindow
    guard rowWindow.length > 0, rowWindow.offset < flattened.count else { return [] }
    let end = min(flattened.count, rowWindow.offset + rowWindow.length)
    return Array(flattened[rowWindow.offset..<end])
  }

  /// The visible products plus the prefetch margin on either side.
  ///
  /// This, not the visible set, is what demands per-row asynchronous work,
  /// and it is the reason a 1,200-product catalog does not produce 1,200
  /// inventory requests even in a port with no invalidation graph at all: the
  /// render walks the window, so a product outside it is never asked about.
  func prefetchProductIDs() -> [ProductID] {
    let flattened = sections().flatMap(\.productIDs)
    let rowWindow = model.rowWindow
    let margin = model.service.profile.prefetchMargin
    guard rowWindow.length > 0, !flattened.isEmpty else { return [] }
    let start = max(0, rowWindow.offset - margin)
    let end = min(flattened.count, rowWindow.offset + rowWindow.length + margin)
    guard start < end else { return [] }
    return Array(flattened[start..<end])
  }

  // MARK: - Pricing

  /// The variant one product's pricing ladder uses, clamped to what exists.
  ///
  /// Clamped exactly where ``StorefrontPricing`` clamps and nowhere else. The
  /// availability computation below is deliberately left unclamped, which is
  /// what the Cog declaration does and therefore what a comparison has to do.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - product: That product.
  /// - Returns: A valid variant index.
  func pricingVariantIndex(of id: ProductID, in product: Product) -> Int {
    let selected = model.selectedVariants[id] ?? 0
    return min(max(0, selected), max(0, product.variants.count - 1))
  }

  /// One product's effective price: the best price book it qualifies for.
  ///
  /// The seventeen-stage ladder, run end to end on every call through
  /// ``StorefrontPricing/effectivePriceWithoutGraph(product:variantIndex:profile:shopper:address:inventory:offer:coupon:cartQuantity:viewRank:method:)``.
  /// Cog gets one cell per stage and therefore recomputes only the stages below
  /// a changed input; this port has no cells at all, so every read pays the
  /// whole ladder for every qualifying book. That is the single largest cost
  /// difference the comparison exists to expose, and it is why this port is
  /// expected to be slow here rather than a sign that something is wrong.
  ///
  /// The live inventory and the personalized offer are demanded only when the
  /// profile's policy prefix actually contains the stage that reads them. That
  /// is not an optimization: Cog's stage graph reads a value only from the
  /// policy that needs it, so a port that demanded an offer for a cart line on
  /// the four-policy `smoke` ladder would start a request Cog is correct never
  /// to make, and would be running a different session.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  func effectivePrice(of id: ProductID) -> Int {
    let productIndex = productIndex()
    guard let product = productIndex[id] else { return 0 }
    let profile = model.service.profile
    let policies = StorefrontPricing.ladder.prefix(profile.pricingPolicyCount)
    let readsInventory =
      policies.contains(.inventoryMarkdown) || policies.contains(.clearance)
    let readsOffer = policies.contains(.personalizedOffer)
    return StorefrontPricing.effectivePriceWithoutGraph(
      product: product,
      variantIndex: pricingVariantIndex(of: id, in: product),
      profile: profile,
      shopper: pricingShopper(),
      address: model.shippingAddress,
      inventory: readsInventory ? inventoryValue(for: id) : .unknown,
      offer: readsOffer ? offerValue(for: id) : .none,
      coupon: model.coupon,
      cartQuantity: model.cartQuantities[id] ?? 0,
      viewRank: model.recentlyViewedRanks[id] ?? 0,
      method: model.shippingMethod
    )
  }

  /// The shopper the pricing ladder prices against.
  ///
  /// A synthesized guest before the account response is accepted, matching the
  /// Cog declarations' `?? .guest` and `?? 0`. An honest resting value rather
  /// than a fabricated member: a policy that read a tier must be able to tell
  /// "not loaded" from "guest", and defaulting to a member would price the
  /// whole catalog wrong for one settlement.
  func pricingShopper() -> Shopper {
    model.signedInShopper ?? Self.guestShopper
  }

  // MARK: - Per-row presentation

  /// Units available for one product's selected variant.
  ///
  /// Unclamped, exactly as the Cog declaration is.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The available units.
  func availableUnits(of id: ProductID) -> Int {
    inventoryValue(for: id).units(forVariant: model.selectedVariants[id] ?? 0)
  }

  /// The badges one product's row shows.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The badges.
  func badges(of id: ProductID) -> ProductBadges {
    guard let product = productIndex()[id] else { return [] }
    var badges: ProductBadges = []

    if effectivePrice(of: id) < product.listPriceCents { badges.insert(.onSale) }

    let availableUnits = availableUnits(of: id)
    let inventory = inventoryValue(for: id)
    if availableUnits == 0 && !inventory.restockable {
      badges.insert(.soldOut)
    } else if availableUnits > 0 && availableUnits <= 3 {
      badges.insert(.lowStock)
    }

    if offerValue(for: id).discountBasisPoints > 0 { badges.insert(.offer) }
    if model.favorites[id] ?? false { badges.insert(.favorite) }
    if (model.recentlyViewedRanks[id] ?? 0) > 0 { badges.insert(.recentlyViewed) }
    if (model.cartQuantities[id] ?? 0) > 0 { badges.insert(.inCart) }

    return badges
  }

  /// Everything one product row renders.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The row.
  func productRow(of id: ProductID) -> ProductRow {
    guard let product = productIndex()[id] else {
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
    let categoryName =
      categories().first { $0.id == product.category }?.name
      ?? "Category \(product.category.raw)"
    return ProductRow(
      productID: id,
      name: product.name,
      categoryName: categoryName,
      priceCents: effectivePrice(of: id),
      listPriceCents: product.listPriceCents,
      availableUnits: availableUnits(of: id),
      badges: badges(of: id),
      cartQuantity: model.cartQuantities[id] ?? 0
    )
  }

  // MARK: - Cart

  /// The cart's products, filtered to those still in the catalog with a
  /// positive quantity.
  func cartLineIDs() -> [ProductID] {
    let productIndex = productIndex()
    return model.cartContents.filter { id in
      guard productIndex[id] != nil else { return false }
      return (model.cartQuantities[id] ?? 0) > 0
    }
  }

  /// One cart line.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The line.
  func cartLine(of id: ProductID) -> CartLine {
    let quantity = model.cartQuantities[id] ?? 0
    let variantIndex = model.selectedVariants[id] ?? 0
    guard let product = productIndex()[id] else {
      return CartLine(
        productID: id,
        name: "",
        variantIndex: variantIndex,
        quantity: quantity,
        unitPriceCents: 0,
        inStock: false
      )
    }
    return CartLine(
      productID: id,
      name: product.name,
      variantIndex: variantIndex,
      quantity: quantity,
      unitPriceCents: effectivePrice(of: id),
      inStock: availableUnits(of: id) >= quantity
    )
  }

  /// Every cart line, in cart order.
  func cartLines() -> [CartLine] {
    cartLineIDs().map { cartLine(of: $0) }
  }

  /// The sum of every line's extended price.
  func cartSubtotal() -> Int {
    cartLines().reduce(0) { $0 + $1.extendedCents }
  }

  /// The best compatible set of promotions for the current cart.
  ///
  /// The bounded dynamic-programming pass, run synchronously because a shopper
  /// who types a coupon expects the total to move on the same frame, and run
  /// again on every read, because this port memoizes nothing.
  func promotionPlan() -> PromotionPlan {
    let cartLines = cartLines()
    guard !cartLines.isEmpty else { return .none }
    return StorefrontKernels.selectPromotions(
      lines: cartLines,
      promotions: StorefrontFixtures.promotions(for: model.service.profile),
      categories: productIndex().mapValues(\.category),
      couponID: model.coupon?.raw
    )
  }

  /// The subtotal after promotions.
  func discountedSubtotal() -> Int {
    max(0, cartSubtotal() - promotionPlan().discountCents)
  }

  /// The cart's money, fully broken down.
  func orderTotal() -> OrderTotal {
    let cartSubtotal = cartSubtotal()
    let promotionPlan = promotionPlan()
    let discountedSubtotal = max(0, cartSubtotal - promotionPlan.discountCents)
    return OrderTotal(
      subtotalCents: cartSubtotal,
      discountCents: promotionPlan.discountCents,
      discountedSubtotalCents: discountedSubtotal,
      taxCents: taxQuoteValue().taxCents,
      shippingCents: shippingQuoteValue().costCents
    )
  }

  /// Whether the cart can be checked out, and why not when it cannot.
  func checkoutReadiness() -> CheckoutReadiness {
    var blockers: [String] = []
    let cartLines = cartLines()
    if cartLines.isEmpty { blockers.append("The cart is empty.") }
    if cartLines.contains(where: { !$0.inStock }) {
      blockers.append("Some items are not available in the quantity requested.")
    }
    if model.signedInShopper == nil { blockers.append("Sign in to check out.") }
    if shippingQuoteValue().estimatedDays == 0 {
      blockers.append("Waiting for a shipping quote.")
    }
    return CheckoutReadiness(isReady: blockers.isEmpty, blockers: blockers)
  }
}
