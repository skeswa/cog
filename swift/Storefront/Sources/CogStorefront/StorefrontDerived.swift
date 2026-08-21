public import Cog

// Everything the Storefront computes, in the order it computes it.
//
// The shape to notice is the funnel: the whole catalog is indexed and scored,
// a filter narrows it, a rank orders it, sections group it, and a window
// materializes about thirty rows. Only the rows inside that window demand
// per-product async work, which is why a 1,200-product catalog does not
// produce 1,200 inventory requests. That asymmetry is the single most
// important thing a fine-grained graph buys a list screen, and this file is
// arranged so it is visible rather than asserted.
//
// Almost every declaration here is equality-gated — most of them for free,
// because their values are `Equatable`. Where equality is what stops an
// invalidation wave, the comment says so.

// MARK: - Query

/// The search text, normalized once for everything downstream.
///
/// Equality-gated, and that gate does real work: typing a trailing space, or
/// changing case, produces the same normalization, so the search index, the
/// suggestion request, and every candidate set stay exactly where they were.
///
/// Normalization is hand-written rather than `Foundation`'s, because this
/// package imports no `Foundation` at all: a fixture that folded case or
/// trimmed whitespace by the host's locale rules would make the workload's
/// inputs depend on device settings.
public let storefrontNormalizedQueryCog = Cog<String>(
  { c in
    let searchQuery = c[searchQueryCog]
    return StorefrontKernels.normalize(searchQuery)
  },
  name: "storefront.normalizedQuery"
)

/// The normalized query, split into tokens.
public let storefrontQueryTokensCog = Cog<[String]>(
  { c in
    let normalizedQuery = c[storefrontNormalizedQueryCog]
    return StorefrontKernels.tokenize(normalizedQuery)
  },
  name: "storefront.queryTokens"
)

// MARK: - Catalog views

/// The accepted catalog's products.
///
/// A value read of the async catalog, so a reload that returns an equal
/// catalog leaves the entire browse graph alone while the status lens still
/// reports the reload.
public let storefrontCatalogProductsCog = Cog<[Product]>(
  { c in
    let storefrontCatalog = c[storefrontCatalogCog]
    return storefrontCatalog.products
  },
  name: "storefront.catalogProducts"
)

/// The accepted catalog's categories, in identifier order.
public let storefrontCategoriesCog = Cog<[Category]>(
  { c in
    let storefrontCatalog = c[storefrontCatalogCog]
    return storefrontCatalog.categories
  },
  name: "storefront.categories"
)

/// Products by identifier.
///
/// The lookup every keyed declaration goes through, so a product's fields are
/// resolved once per catalog rather than once per row per turn.
public let storefrontProductIndexCog = Cog<[ProductID: Product]>(
  { c in
    let catalogProducts = c[storefrontCatalogProductsCog]
    return Dictionary(uniqueKeysWithValues: catalogProducts.map { ($0.id, $0) })
  },
  name: "storefront.productIndex"
)

// MARK: - Per-product search state

/// One product's relevance score for the current query.
///
/// Keyed, because a score is a fact about a product and a query — and because
/// keeping it keyed is what lets a query change rescore only the products the
/// index still considers candidates.
///
/// It deliberately does **not** read this session's view history. Boosting a
/// product you just looked at is a real ranking feature, but it would make
/// opening a product invalidate its score, and a score change re-ranks the
/// whole result set; a list that reorders itself while you are looking at it is
/// not a storefront anybody ships. The view history reaches the badge and the
/// pricing nudge instead, both of which are per-product.
public let storefrontSearchScoreCogs = CogBox<Int, ProductID>(
  { c, id in
    let productIndex = c[storefrontProductIndexCog]
    guard let product = productIndex[id] else { return 0 }
    let queryTokens = c[storefrontQueryTokensCog]
    return StorefrontKernels.relevanceScore(product: product, tokens: queryTokens)
  },
  name: "storefront.searchScore"
)

/// Whether one product survives the filter bar.
///
/// Two deliberate omissions, and both are the difference between a workload
/// that measures Cog and one that measures a design mistake.
///
/// It reads the **catalog's** stock rather than live inventory, because a
/// filter that consulted live inventory would demand an inventory request for
/// every product in the catalog the moment the shopper flipped a switch. Live
/// inventory belongs to the rows that are on screen.
///
/// And it asks whether *any* variant is stocked rather than the selected one,
/// so selecting a variant does not invalidate eligibility — and therefore does
/// not re-rank the catalog. That is both what a real storefront means by "in
/// stock" in a list filter and what keeps a per-product write a per-product
/// wave. The first draft read the selected variant here, and `M10` measured
/// one variant selection at 100 ms on the standard profile because of it.
public let storefrontFilterEligibilityCogs = CogBox<Bool, ProductID>(
  { c, id in
    let productIndex = c[storefrontProductIndexCog]
    guard let product = productIndex[id] else { return false }
    let selectedCategory = c[selectedCategoryCog]
    if let selectedCategory, product.category != selectedCategory { return false }
    let inStockOnly = c[inStockOnlyCog]
    guard inStockOnly else { return true }
    return product.variants.contains { $0.catalogStock > 0 }
  },
  name: "storefront.filterEligibility"
)

// MARK: - The funnel

/// Products the search index matched, ascending by identifier.
public let storefrontSearchCandidateIDsCog = Cog<[ProductID]>(
  { c in
    let storefrontSearchIndex = c[storefrontSearchIndexCog]
    let queryTokens = c[storefrontQueryTokensCog]
    let catalogProducts = c[storefrontCatalogProductsCog]
    let ordinals = StorefrontKernels.candidates(
      in: storefrontSearchIndex,
      tokens: queryTokens,
      productCount: catalogProducts.count
    )
    return ordinals.map { ProductID($0) }
  },
  name: "storefront.searchCandidates"
)

/// Candidates that survive the filter bar.
public let storefrontEligibleProductIDsCog = Cog<[ProductID]>(
  { c in
    let searchCandidateIDs = c[storefrontSearchCandidateIDsCog]
    return searchCandidateIDs.filter { id in
      let filterEligibility = c[storefrontFilterEligibilityCogs[id]]
      return filterEligibility
    }
  },
  name: "storefront.eligibleProducts"
)

/// Eligible products in presentation order.
///
/// Price ordering uses the catalog's list price, not the sixteen-stage
/// effective price and not the selected variant's adjusted one. That is a real
/// product decision as much as a performance one: sorting a thousand products
/// by a personalized price would demand a personalized offer and a live
/// inventory reading for every one of them, and no storefront does that to sort
/// a list. Keeping the variant out of it means selecting a variant reorders
/// nothing, which is also what a shopper expects.
public let storefrontRankedProductIDsCog = Cog<[ProductID]>(
  { c in
    let eligibleProductIDs = c[storefrontEligibleProductIDsCog]
    let productIndex = c[storefrontProductIndexCog]
    let sortMode = c[sortModeCog]
    let catalogProducts = c[storefrontCatalogProductsCog]

    var scores: [Int: Int] = [:]
    var prices: [Int: Int] = [:]
    scores.reserveCapacity(eligibleProductIDs.count)
    prices.reserveCapacity(eligibleProductIDs.count)
    for id in eligibleProductIDs {
      let searchScore = c[storefrontSearchScoreCogs[id]]
      scores[id.raw] = searchScore
      guard let product = productIndex[id] else { continue }
      prices[id.raw] = product.listPriceCents
    }

    return StorefrontKernels.rank(
      candidates: eligibleProductIDs.map(\.raw),
      products: catalogProducts,
      scores: scores,
      prices: prices,
      mode: sortMode
    )
  },
  name: "storefront.rankedProducts"
)

/// The ranked products, grouped into the sections the browse list renders.
///
/// The first section is the cross-category best-match band; the rest group by
/// category in the order the ranking first met them. Sections exist so the
/// list has a nested `ForEach` over a *dynamic* number of sections with a
/// constant number of views per row, which is the shape Apple's own list
/// guidance calls for.
public let storefrontSectionsCog = Cog<[StorefrontSection]>(
  { c in
    let rankedProductIDs = c[storefrontRankedProductIDsCog]
    let productIndex = c[storefrontProductIndexCog]
    let storefrontCategories = c[storefrontCategoriesCog]
    let categoryNames = Dictionary(
      uniqueKeysWithValues: storefrontCategories.map { ($0.id, $0.name) }
    )

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
  },
  name: "storefront.sections"
)

/// The products inside the materialized window, in list order.
public let storefrontVisibleProductIDsCog = Cog<[ProductID]>(
  { c in
    let storefrontSections = c[storefrontSectionsCog]
    let rowWindow = c[rowWindowCog]
    let flattened = storefrontSections.flatMap(\.productIDs)
    guard rowWindow.length > 0, rowWindow.offset < flattened.count else { return [] }
    let end = min(flattened.count, rowWindow.offset + rowWindow.length)
    return Array(flattened[rowWindow.offset..<end])
  },
  name: "storefront.visibleProducts"
)

/// The visible products plus the prefetch margin on either side.
///
/// This — not the visible set — is what actually demands per-row async work,
/// which is why scrolling one row does not start a request storm and why the
/// two sets are separate declarations rather than one with an adjustment.
public let storefrontPrefetchProductIDsCog = Cog<[ProductID]>(
  { c in
    let storefrontSections = c[storefrontSectionsCog]
    let rowWindow = c[rowWindowCog]
    let storefrontService = c[storefrontServiceCog]
    let margin = storefrontService.profile.prefetchMargin
    let flattened = storefrontSections.flatMap(\.productIDs)
    guard rowWindow.length > 0, !flattened.isEmpty else { return [] }
    let start = max(0, rowWindow.offset - margin)
    let end = min(flattened.count, rowWindow.offset + rowWindow.length + margin)
    guard start < end else { return [] }
    return Array(flattened[start..<end])
  },
  name: "storefront.prefetchProducts"
)

// MARK: - Pricing

/// One node of the pricing pipeline.
///
/// Stage zero is the price book's base; stage `n` applies
/// ``StorefrontPricing/ladder``'s `n - 1`th policy to stage `n - 1`. The
/// recursion is what makes this one declaration a sixteen-node chain per
/// product per book, and the `switch` is what makes each node depend on only
/// the inputs its own policy reads — so changing the coupon invalidates the
/// coupon stage and everything below it, and nothing above it.
public let storefrontPricingStageCogs = CogBox<Int, StorefrontPricing.StageKey>(
  { c, key in
    guard let policy = key.policy, let previous = key.previous else {
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      let selectedVariant = c[selectedVariantCogs[key.productID]]
      let variantIndex = min(max(0, selectedVariant), max(0, product.variants.count - 1))
      return StorefrontPricing.basePrice(
        product: product,
        book: key.book,
        variantIndex: variantIndex
      )
    }
    let cents = c[storefrontPricingStageCogs[previous]]

    switch policy {
    case .regionalMarket:
      let shippingAddress = c[shippingAddressCog]
      return StorefrontPricing.regionalMarket(cents, market: shippingAddress.market)
    case .membershipTier:
      let signedInShopper = c[signedInShopperCog]
      return StorefrontPricing.membershipTier(cents, tier: signedInShopper?.tier ?? .guest)
    case .categoryCampaign:
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      return StorefrontPricing.categoryCampaign(cents, category: product.category)
    case .couponCode:
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      let coupon = c[couponCog]
      let storefrontService = c[storefrontServiceCog]
      return StorefrontPricing.couponCode(
        cents,
        coupon: coupon,
        category: product.category,
        promotions: StorefrontFixtures.promotions(for: storefrontService.profile)
      )
    case .bundleQuantity:
      let cartQuantity = c[cartQuantityCogs[key.productID]]
      return StorefrontPricing.bundleQuantity(cents, cartQuantity: cartQuantity)
    case .inventoryMarkdown:
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      let selectedVariant = c[selectedVariantCogs[key.productID]]
      let variantIndex = min(max(0, selectedVariant), max(0, product.variants.count - 1))
      let storefrontInventory = c[storefrontInventoryCogs[key.productID]]
      return StorefrontPricing.inventoryMarkdown(
        cents,
        availableUnits: storefrontInventory.units(forVariant: variantIndex)
      )
    case .clearance:
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      let selectedVariant = c[selectedVariantCogs[key.productID]]
      let variantIndex = min(max(0, selectedVariant), max(0, product.variants.count - 1))
      let storefrontInventory = c[storefrontInventoryCogs[key.productID]]
      return StorefrontPricing.clearance(
        cents,
        restockable: storefrontInventory.restockable,
        availableUnits: storefrontInventory.units(forVariant: variantIndex)
      )
    case .loyaltyBurn:
      let signedInShopper = c[signedInShopperCog]
      return StorefrontPricing.loyaltyBurn(
        cents,
        loyaltyPoints: signedInShopper?.loyaltyPoints ?? 0
      )
    case .variantPremium:
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      let selectedVariant = c[selectedVariantCogs[key.productID]]
      let variantIndex = min(max(0, selectedVariant), max(0, product.variants.count - 1))
      let delta =
        product.variants.isEmpty ? 0 : product.variants[variantIndex].priceDeltaCents
      return StorefrontPricing.variantPremium(cents, delta: delta)
    case .ecoLevy:
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      return StorefrontPricing.ecoLevy(cents, category: product.category)
    case .shippingSubsidy:
      let shippingMethod = c[shippingMethodCog]
      return StorefrontPricing.shippingSubsidy(cents, method: shippingMethod)
    case .competitorMatch:
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      return StorefrontPricing.competitorMatch(cents, product: product)
    case .recentlyViewedNudge:
      let recentlyViewedRank = c[recentlyViewedRankCogs[key.productID]]
      return StorefrontPricing.recentlyViewedNudge(cents, viewRank: recentlyViewedRank)
    case .personalizedOffer:
      let storefrontOffer = c[storefrontOfferCogs[key.productID]]
      return StorefrontPricing.personalizedOffer(cents, offer: storefrontOffer)
    case .priceFloor:
      let productIndex = c[storefrontProductIndexCog]
      guard let product = productIndex[key.productID] else { return 0 }
      return StorefrontPricing.priceFloor(cents, product: product)
    case .charmRounding:
      return StorefrontPricing.charmRounding(cents)
    }
  },
  name: "storefront.pricingStage"
)

/// One product's effective price: the best price book it qualifies for.
///
/// The top of the pricing pipeline, and the value a row renders. Equality
/// gating here is what makes charm rounding pay: many upstream changes collapse
/// to the same price tag, and a row that would otherwise re-render does not.
public let storefrontEffectivePriceCogs = CogBox<Int, ProductID>(
  { c, id in
    let productIndex = c[storefrontProductIndexCog]
    guard let product = productIndex[id] else { return 0 }
    let storefrontService = c[storefrontServiceCog]
    let profile = storefrontService.profile
    let signedInShopper = c[signedInShopperCog]
    let tier = signedInShopper?.tier ?? .guest
    let stage = profile.pricingPolicyCount

    var best: Int?
    for book in StorefrontPricing.PriceBook.allCases.prefix(profile.priceBookCount) {
      guard book.qualifies(for: tier) else { continue }
      let key = StorefrontPricing.StageKey(productID: id, book: book, stage: stage)
      let price = c[storefrontPricingStageCogs[key]]
      best = best.map { min($0, price) } ?? price
    }
    return best ?? product.listPriceCents
  },
  name: "storefront.effectivePrice"
)

// MARK: - Per-row presentation

/// Units available for one product's selected variant.
public let storefrontAvailabilityCogs = CogBox<Int, ProductID>(
  { c, id in
    let storefrontInventory = c[storefrontInventoryCogs[id]]
    let selectedVariant = c[selectedVariantCogs[id]]
    return storefrontInventory.units(forVariant: selectedVariant)
  },
  name: "storefront.availability"
)

/// The badges one product's row shows.
///
/// An `OptionSet`, so this equality gate is one integer comparison and a row
/// whose badges did not change does not re-render even though several inputs
/// moved.
public let storefrontBadgesCogs = CogBox<ProductBadges, ProductID>(
  { c, id in
    let productIndex = c[storefrontProductIndexCog]
    guard let product = productIndex[id] else { return [] }
    var badges: ProductBadges = []

    let effectivePrice = c[storefrontEffectivePriceCogs[id]]
    if effectivePrice < product.listPriceCents { badges.insert(.onSale) }

    let availability = c[storefrontAvailabilityCogs[id]]
    let storefrontInventory = c[storefrontInventoryCogs[id]]
    if availability == 0 && !storefrontInventory.restockable {
      badges.insert(.soldOut)
    } else if availability > 0 && availability <= 3 {
      badges.insert(.lowStock)
    }

    let storefrontOffer = c[storefrontOfferCogs[id]]
    if storefrontOffer.discountBasisPoints > 0 { badges.insert(.offer) }

    let favorite = c[favoriteCogs[id]]
    if favorite { badges.insert(.favorite) }

    let recentlyViewedRank = c[recentlyViewedRankCogs[id]]
    if recentlyViewedRank > 0 { badges.insert(.recentlyViewed) }

    let cartQuantity = c[cartQuantityCogs[id]]
    if cartQuantity > 0 { badges.insert(.inCart) }

    return badges
  },
  name: "storefront.badges"
)

/// Everything one product row renders.
///
/// A row reads this and nothing else, so a list row's body depends on one
/// value rather than nine — and an inventory burst that changes an offscreen
/// product changes no row that is on screen.
public let storefrontProductRowCogs = CogBox<ProductRow, ProductID>(
  { c, id in
    let productIndex = c[storefrontProductIndexCog]
    let storefrontCategories = c[storefrontCategoriesCog]
    guard let product = productIndex[id] else {
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
    let effectivePrice = c[storefrontEffectivePriceCogs[id]]
    let availability = c[storefrontAvailabilityCogs[id]]
    let badges = c[storefrontBadgesCogs[id]]
    let cartQuantity = c[cartQuantityCogs[id]]
    let categoryName =
      storefrontCategories.first { $0.id == product.category }?.name
      ?? "Category \(product.category.raw)"
    return ProductRow(
      productID: id,
      name: product.name,
      categoryName: categoryName,
      priceCents: effectivePrice,
      listPriceCents: product.listPriceCents,
      availableUnits: availability,
      badges: badges,
      cartQuantity: cartQuantity
    )
  },
  name: "storefront.productRow"
)

// MARK: - Cart

/// The cart's products, filtered to the ones still in the catalog with a
/// positive quantity.
public let storefrontCartLineIDsCog = Cog<[ProductID]>(
  { c in
    let cartContents = c[cartContentsCog]
    let productIndex = c[storefrontProductIndexCog]
    return cartContents.filter { id in
      guard productIndex[id] != nil else { return false }
      let cartQuantity = c[cartQuantityCogs[id]]
      return cartQuantity > 0
    }
  },
  name: "storefront.cartLineIDs"
)

/// One cart line.
public let storefrontCartLineCogs = CogBox<CartLine, ProductID>(
  { c, id in
    let productIndex = c[storefrontProductIndexCog]
    let cartQuantity = c[cartQuantityCogs[id]]
    let selectedVariant = c[selectedVariantCogs[id]]
    guard let product = productIndex[id] else {
      return CartLine(
        productID: id,
        name: "",
        variantIndex: selectedVariant,
        quantity: cartQuantity,
        unitPriceCents: 0,
        inStock: false
      )
    }
    let effectivePrice = c[storefrontEffectivePriceCogs[id]]
    let availability = c[storefrontAvailabilityCogs[id]]
    return CartLine(
      productID: id,
      name: product.name,
      variantIndex: selectedVariant,
      quantity: cartQuantity,
      unitPriceCents: effectivePrice,
      inStock: availability >= cartQuantity
    )
  },
  name: "storefront.cartLine"
)

/// Every cart line, in cart order.
public let storefrontCartLinesCog = Cog<[CartLine]>(
  { c in
    let cartLineIDs = c[storefrontCartLineIDsCog]
    return cartLineIDs.map { id in
      let cartLine = c[storefrontCartLineCogs[id]]
      return cartLine
    }
  },
  name: "storefront.cartLines"
)

/// The sum of every line's extended price.
public let storefrontCartSubtotalCog = Cog<Int>(
  { c in
    let cartLines = c[storefrontCartLinesCog]
    return cartLines.reduce(0) { $0 + $1.extendedCents }
  },
  name: "storefront.cartSubtotal"
)

/// The best compatible set of promotions for the current cart.
///
/// The bounded dynamic-programming pass, run synchronously because a shopper
/// who types a coupon expects the total to move on the same frame. It is the
/// most expensive synchronous computation in the workload, and the reason the
/// cart cut of the benchmark exists.
public let storefrontPromotionPlanCog = Cog<PromotionPlan>(
  { c in
    let cartLines = c[storefrontCartLinesCog]
    guard !cartLines.isEmpty else { return .none }
    let productIndex = c[storefrontProductIndexCog]
    let coupon = c[couponCog]
    let storefrontService = c[storefrontServiceCog]
    let categories = productIndex.mapValues(\.category)
    return StorefrontKernels.selectPromotions(
      lines: cartLines,
      promotions: StorefrontFixtures.promotions(for: storefrontService.profile),
      categories: categories,
      couponID: coupon?.raw
    )
  },
  name: "storefront.promotionPlan"
)

/// The subtotal after promotions.
///
/// Equality-gated, and it is the gate that matters most in the whole graph:
/// the shipping and tax quotes are downstream of it, so a cart change that
/// leaves the discounted subtotal alone starts no request at all.
public let storefrontDiscountedSubtotalCog = Cog<Int>(
  { c in
    let cartSubtotal = c[storefrontCartSubtotalCog]
    let promotionPlan = c[storefrontPromotionPlanCog]
    return max(0, cartSubtotal - promotionPlan.discountCents)
  },
  name: "storefront.discountedSubtotal"
)

/// The cart's money, fully broken down.
public let storefrontOrderTotalCog = Cog<OrderTotal>(
  { c in
    let cartSubtotal = c[storefrontCartSubtotalCog]
    let promotionPlan = c[storefrontPromotionPlanCog]
    let discountedSubtotal = c[storefrontDiscountedSubtotalCog]
    let storefrontTaxQuote = c[storefrontTaxQuoteCog]
    let storefrontShippingQuote = c[storefrontShippingQuoteCog]
    return OrderTotal(
      subtotalCents: cartSubtotal,
      discountCents: promotionPlan.discountCents,
      discountedSubtotalCents: discountedSubtotal,
      taxCents: storefrontTaxQuote.taxCents,
      shippingCents: storefrontShippingQuote.costCents
    )
  },
  name: "storefront.orderTotal"
)

/// Whether the cart can be checked out, and why not when it cannot.
public let storefrontCheckoutReadinessCog = Cog<CheckoutReadiness>(
  { c in
    var blockers: [String] = []
    let cartLines = c[storefrontCartLinesCog]
    if cartLines.isEmpty { blockers.append("The cart is empty.") }
    if cartLines.contains(where: { !$0.inStock }) {
      blockers.append("Some items are not available in the quantity requested.")
    }
    let signedInShopper = c[signedInShopperCog]
    if signedInShopper == nil { blockers.append("Sign in to check out.") }
    let storefrontShippingQuote = c[storefrontShippingQuoteCog]
    if storefrontShippingQuote.estimatedDays == 0 {
      blockers.append("Waiting for a shipping quote.")
    }
    return CheckoutReadiness(isReady: blockers.isEmpty, blockers: blockers)
  },
  name: "storefront.checkoutReadiness"
)
