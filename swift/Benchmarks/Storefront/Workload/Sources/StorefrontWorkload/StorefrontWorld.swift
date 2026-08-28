/// A shadow model of the session, and the expectations derived from it.
///
/// Every checkpoint in the trace compares the graph against **this**, never
/// against a number copied out of a passing run. The rule matters: a recorded
/// observation only says what happened once, whereas a value recomputed from
/// the profile and the events the driver issued is a claim about what *should*
/// happen, and a graph that quietly started computing something else fails it.
///
/// The shadow is deliberately written the long way: plain loops over plain
/// values, no graph. Correctness runs may evaluate it at every checkpoint. A
/// benchmark prepares its fixture-derived immutable storage before timing,
/// suppresses phase checks while timing, and evaluates only the final state
/// after timing stops.
public nonisolated struct StorefrontWorld: Sendable {
  /// The world's size.
  public let profile: StorefrontProfile

  /// The catalog the fixtures produce for this profile.
  public let catalog: CatalogSnapshot

  /// The shopper the account response carries.
  public let shopper: Shopper

  /// The raw search text.
  public var query = ""

  /// The selected category, or `nil` for all.
  public var category: CategoryID?

  /// How results are ordered.
  public var sortMode: SortMode = .relevance

  /// Whether out-of-stock products are hidden.
  public var inStockOnly = false

  /// The materialized row window.
  public var window: RowWindow

  /// The applied coupon.
  public var coupon: CouponCode?

  /// Where the order ships.
  public var address = StorefrontFixtures.startingAddress

  /// How the order ships.
  public var method: ShippingMethod = .standard

  /// The cart's membership list, in insertion order.
  public var cartContents: [ProductID] = []

  /// Per-product cart quantities.
  public var cartQuantities: [ProductID: Int] = [:]

  /// Per-product selected variants.
  public var variants: [ProductID: Int] = [:]

  /// Per-product recency ranks.
  public var viewRanks: [ProductID: Int] = [:]

  /// Per-product inventory generations.
  public var inventoryGenerations: [ProductID: Int] = [:]

  /// Whether the account response has been accepted.
  public var isSignedIn = false

  /// The search index over the catalog, built once.
  public let searchIndex: StorefrontKernels.SearchIndex

  /// Products by identifier, built once.
  ///
  /// Stored because checkpoints read it often. Rebuilding a 1,200-entry map on
  /// each read would waste verification time.
  public let productIndex: [ProductID: Product]

  /// Category by identifier, built once.
  public let categoryNames: [CategoryID: String]

  /// Creates a shadow world matching a freshly bootstrapped runtime.
  ///
  /// - Parameter profile: The world's size.
  public init(profile: StorefrontProfile) {
    self.profile = profile
    catalog = StorefrontFixtures.catalog(for: profile)
    shopper = StorefrontFixtures.shopper(for: profile)
    window = RowWindow(offset: 0, length: profile.viewportRowCount)
    searchIndex = StorefrontKernels.buildSearchIndex(products: catalog.products)
    productIndex = Dictionary(uniqueKeysWithValues: catalog.products.map { ($0.id, $0) })
    categoryNames = Dictionary(uniqueKeysWithValues: catalog.categories.map { ($0.id, $0.name) })
  }

  // MARK: - Derived expectations

  /// The shopper's tier, or `guest` before the account lands.
  public var tier: MembershipTier { isSignedIn ? shopper.tier : .guest }

  /// The variant selected for one product, clamped to what exists.
  ///
  /// - Parameter id: Which product.
  /// - Returns: A valid variant index.
  public func variantIndex(for id: ProductID) -> Int {
    guard let product = catalog.products.first(where: { $0.id == id }) else { return 0 }
    let requested = variants[id] ?? 0
    return min(max(0, requested), max(0, product.variants.count - 1))
  }

  /// Whether one product survives the filter bar.
  ///
  /// The normative definition of eligibility, including the deliberate choice
  /// to consult the catalog's recorded stock rather than live inventory. The
  /// shadow is the reference every runtime's filter stage is compared against,
  /// not a transcription of one runtime's implementation: the Cog port's
  /// `storefrontFilterEligibilityCogs` mirrors *this*, and so must the
  /// equivalent stage in every other port.
  ///
  /// - Parameter product: The product to test.
  /// - Returns: Whether it survives.
  public func isEligible(_ product: Product) -> Bool {
    if let category, product.category != category { return false }
    guard inStockOnly else { return true }
    return product.variants.contains { $0.catalogStock > 0 }
  }

  /// The products the browse list would rank, in order.
  public var rankedProductIDs: [ProductID] {
    let tokens = StorefrontKernels.tokenize(StorefrontKernels.normalize(query))
    let candidateOrdinals = StorefrontKernels.candidates(
      in: searchIndex,
      tokens: tokens,
      productCount: catalog.products.count
    )
    var eligible: [Int] = []
    var scores: [Int: Int] = [:]
    var prices: [Int: Int] = [:]
    for ordinal in candidateOrdinals {
      let product = catalog.products[ordinal]
      guard isEligible(product) else { continue }
      eligible.append(ordinal)
      scores[ordinal] = StorefrontKernels.relevanceScore(product: product, tokens: tokens)
      prices[ordinal] = product.listPriceCents
    }
    return StorefrontKernels.rank(
      candidates: eligible,
      products: catalog.products,
      scores: scores,
      prices: prices,
      mode: sortMode
    )
  }

  /// The ranked products flattened through the section grouping.
  ///
  /// The normative section order: a cross-category best-match band of at most
  /// twelve, then the remainder grouped by category in first-seen order. Every
  /// runtime's sectioning stage, `storefrontSectionsCog` in the Cog port, is
  /// held to exactly this.
  public var flattenedSectionOrder: [ProductID] {
    let ranked = rankedProductIDs
    let topBandCount = min(ranked.count, 12)
    var result = Array(ranked.prefix(topBandCount))
    var order: [CategoryID] = []
    var grouped: [CategoryID: [ProductID]] = [:]
    for id in ranked.dropFirst(topBandCount) {
      guard let product = productIndex[id] else { continue }
      if grouped[product.category] == nil { order.append(product.category) }
      grouped[product.category, default: []].append(id)
    }
    for category in order { result.append(contentsOf: grouped[category] ?? []) }
    return result
  }

  /// The products the list would have on screen.
  public var visibleProductIDs: [ProductID] {
    let flattened = flattenedSectionOrder
    guard window.length > 0, window.offset < flattened.count else { return [] }
    let end = min(flattened.count, window.offset + window.length)
    return Array(flattened[window.offset..<end])
  }

  /// The products whose per-row async work the list actually demands.
  ///
  /// The window widened by the profile's prefetch margin on each side, clamped
  /// to the list. This is the set with live keyed state; everything outside it
  /// is why a 1,200-product catalog does not produce 1,200 inventory requests.
  public var prefetchProductIDs: [ProductID] {
    let flattened = flattenedSectionOrder
    guard window.length > 0, !flattened.isEmpty else { return [] }
    let start = max(0, window.offset - profile.prefetchMargin)
    let end = min(flattened.count, window.offset + window.length + profile.prefetchMargin)
    guard start < end else { return [] }
    return Array(flattened[start..<end])
  }

  /// The accepted inventory reading for one product.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The reading at this product's current generation.
  public func inventory(for id: ProductID) -> InventoryReading {
    StorefrontFixtures.inventory(
      for: id,
      generation: inventoryGenerations[id] ?? 0,
      profile: profile
    )
  }

  /// The accepted personalized offer for one product.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The offer, or none while signed out.
  public func offer(for id: ProductID) -> PersonalizedOffer {
    isSignedIn ? StorefrontFixtures.offer(for: id, shopper: shopper) : .none
  }

  /// The price the sixteen-stage ladder would produce for one product.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  public func effectivePrice(for id: ProductID) -> Int {
    guard let product = productIndex[id] else { return 0 }
    var shadowShopper = shopper
    if !isSignedIn {
      shadowShopper = Shopper(
        accountID: shopper.accountID,
        name: shopper.name,
        tier: .guest,
        taste: shopper.taste,
        loyaltyPoints: 0
      )
    }
    return StorefrontPricing.effectivePriceWithoutGraph(
      product: product,
      variantIndex: variantIndex(for: id),
      profile: profile,
      shopper: shadowShopper,
      address: address,
      inventory: inventory(for: id),
      offer: offer(for: id),
      coupon: coupon,
      cartQuantity: cartQuantities[id] ?? 0,
      viewRank: viewRanks[id] ?? 0,
      method: method
    )
  }

  /// The badges one product's row would show.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The badges.
  public func badges(for id: ProductID) -> ProductBadges {
    guard let product = productIndex[id] else { return [] }
    var badges: ProductBadges = []
    if effectivePrice(for: id) < product.listPriceCents { badges.insert(.onSale) }
    let reading = inventory(for: id)
    let units = reading.units(forVariant: variantIndex(for: id))
    if units == 0 && !reading.restockable {
      badges.insert(.soldOut)
    } else if units > 0 && units <= 3 {
      badges.insert(.lowStock)
    }
    if offer(for: id).discountBasisPoints > 0 { badges.insert(.offer) }
    if favorites.contains(id) { badges.insert(.favorite) }
    if (viewRanks[id] ?? 0) > 0 { badges.insert(.recentlyViewed) }
    if (cartQuantities[id] ?? 0) > 0 { badges.insert(.inCart) }
    return badges
  }

  /// Products the shopper has favorited.
  public var favorites: Set<ProductID> = []

  /// The digest the browse reaction would compute for the visible rows.
  public var visibleChecksum: Int {
    var checksum = 0
    for id in visibleProductIDs {
      checksum = StorefrontKernels.mix(checksum, id.raw)
      checksum = StorefrontKernels.mix(checksum, effectivePrice(for: id))
      checksum = StorefrontKernels.mix(
        checksum,
        inventory(for: id).units(forVariant: variantIndex(for: id))
      )
      checksum = StorefrontKernels.mix(checksum, badges(for: id).rawValue)
      checksum = StorefrontKernels.mix(checksum, cartQuantities[id] ?? 0)
    }
    return checksum
  }

  /// The cart's lines, in cart order.
  public var cartLines: [CartLine] {
    cartContents.compactMap { id -> CartLine? in
      guard let product = productIndex[id] else { return nil }
      let quantity = cartQuantities[id] ?? 0
      guard quantity > 0 else { return nil }
      let variant = variantIndex(for: id)
      let units = inventory(for: id).units(forVariant: variant)
      return CartLine(
        productID: id,
        name: product.name,
        variantIndex: variant,
        quantity: quantity,
        unitPriceCents: effectivePrice(for: id),
        inStock: units >= quantity
      )
    }
  }

  /// The best compatible promotion set for the current cart.
  public var promotionPlan: PromotionPlan {
    let lines = cartLines
    guard !lines.isEmpty else { return .none }
    return StorefrontKernels.selectPromotions(
      lines: lines,
      promotions: StorefrontFixtures.promotions(for: profile),
      categories: productIndex.mapValues(\.category),
      couponID: coupon?.raw
    )
  }

  /// The cart's money, assuming both quotes have been accepted.
  ///
  /// - Returns: The order total.
  public func orderTotal() -> OrderTotal {
    let lines = cartLines
    let subtotal = lines.reduce(0) { $0 + $1.extendedCents }
    let discount = promotionPlan.discountCents
    let discounted = max(0, subtotal - discount)
    let tax = StorefrontFixtures.taxQuote(
      discountedSubtotalCents: discounted,
      address: address
    )
    let shipping = StorefrontFixtures.shippingQuote(
      subtotalCents: discounted,
      address: address,
      method: method,
      lineCount: lines.count
    )
    return OrderTotal(
      subtotalCents: subtotal,
      discountCents: discount,
      discountedSubtotalCents: discounted,
      taxCents: tax.taxCents,
      shippingCents: shipping.costCents
    )
  }
}
