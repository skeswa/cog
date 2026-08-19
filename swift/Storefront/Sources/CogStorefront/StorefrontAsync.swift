public import Cog

// Async state at four depths of the graph, which is the point of this file.
//
// A macrobenchmark whose only async work sits at the root measures a loading
// screen. Real storefronts await at every level: the catalog at the root, an
// index and a recommender in the middle, inventory and offers per row, quotes
// downstream of a settled cart, and a detail payload at the leaf. Each of those
// invalidates a different amount of the graph when it lands, and that
// difference is the thing worth measuring.
//
// Every selector below captures its dependencies synchronously and hands back
// `.run { @concurrent … }`. Reads performed *inside* the returned work are
// ordinary Swift reads and do not join the graph, which is why the service, the
// products, and the shopper are all read before the closure is built.

// MARK: - Root

/// The catalog, fetched once per session.
///
/// The root of the browse half of the graph: the product index, the search
/// index, every price ladder, and every row value are downstream of this one
/// response.
public let storefrontCatalogCog = AsyncCog<CatalogSnapshot>(
  default: .empty,
  name: "storefront.catalog"
) { c in
  let storefrontService = c[storefrontServiceCog]
  return .run { @concurrent in
    try await storefrontService.catalog()
  }
}

/// The signed-in shopper's account, fetched once per session.
///
/// Rests at `nil`, which is an honest resting value rather than a fabricated
/// guest: pricing policies that read a tier must be able to tell "not loaded"
/// from "guest", and a defaulted guest would silently price the whole catalog
/// wrong for one turn.
public let storefrontAccountCog = AsyncCog<Shopper?>(
  default: nil,
  name: "storefront.account"
) { c in
  let storefrontService = c[storefrontServiceCog]
  return .run { @concurrent in
    try await storefrontService.account()
  }
}

// MARK: - Mid-graph

/// The inverted search index over the accepted catalog.
///
/// Mid-graph on purpose: it depends on an async response and is itself async,
/// so accepting a catalog schedules a second wave of work rather than settling
/// the screen. Building it is the largest single piece of computation in the
/// workload, which is exactly why it is off the MainActor.
public let storefrontSearchIndexCog = AsyncCog<StorefrontKernels.SearchIndex>(
  default: .empty,
  name: "storefront.searchIndex"
) { c in
  let storefrontService = c[storefrontServiceCog]
  let catalogProducts = c[storefrontCatalogProductsCog]
  return .run { @concurrent in
    try await storefrontService.searchIndex(products: catalogProducts)
  }
}

/// Suggestions for the query the shopper is typing.
///
/// Keyed off the *normalized* query, so two keystrokes that normalize the same
/// way do not start two requests. Each distinct normalization is a new
/// generation; the standard trace deliberately completes a stale one to prove
/// the graph refuses it.
public let storefrontSuggestionsCog = AsyncCog<[String]>(
  default: [],
  name: "storefront.suggestions"
) { c in
  let storefrontService = c[storefrontServiceCog]
  let normalizedQuery = c[storefrontNormalizedQueryCog]
  let catalogProducts = c[storefrontCatalogProductsCog]
  return .run { @concurrent in
    guard !normalizedQuery.isEmpty else { return [] }
    return try await storefrontService.suggestions(
      query: normalizedQuery,
      products: catalogProducts
    )
  }
}

/// Personalized recommendations, scored over the whole catalog.
///
/// Depends on both async roots, so it cannot start until each has landed —
/// which is what makes it the workload's one genuinely three-deep async chain.
public let storefrontRecommendationsCog = AsyncCog<[ProductID]>(
  default: [],
  name: "storefront.recommendations"
) { c in
  let storefrontService = c[storefrontServiceCog]
  let catalogProducts = c[storefrontCatalogProductsCog]
  let signedInShopper = c[signedInShopperCog]
  return .run { @concurrent in
    guard let signedInShopper else { return [] }
    return try await storefrontService.recommendations(
      products: catalogProducts,
      shopper: signedInShopper
    )
  }
}

// MARK: - Keyed row data

/// Live inventory for one product.
///
/// The keyed generation is a dependency, so an inventory burst that touches
/// this product invalidates exactly this state and no other. A product whose
/// row is not demanded has no state at all, so a burst covering it costs
/// nothing — which is the claim the burst checkpoint exists to prove.
public let storefrontInventoryCogs = AsyncCogBox<InventoryReading, ProductID>(
  default: .unknown,
  name: "storefront.inventory"
) { c, id in
  let storefrontService = c[storefrontServiceCog]
  let inventoryGeneration = c[inventoryGenerationCogs[id]]
  return .run { @concurrent in
    try await storefrontService.inventory(for: id, generation: inventoryGeneration)
  }
}

/// The personalized offer for one product.
///
/// Depends on the shopper, so signing in or out replaces every demanded
/// offer — a wide, keyed invalidation wave with a narrow trigger.
public let storefrontOfferCogs = AsyncCogBox<PersonalizedOffer, ProductID>(
  default: .none,
  name: "storefront.offer"
) { c, id in
  let storefrontService = c[storefrontServiceCog]
  let signedInShopper = c[signedInShopperCog]
  return .run { @concurrent in
    guard let signedInShopper else { return .none }
    return try await storefrontService.offer(for: id, shopper: signedInShopper)
  }
}

// MARK: - Detail leaf

/// The detail payload for one product.
///
/// A leaf: nothing on the browse screen reads it, so it is demanded only while
/// a detail screen is open and released once the shopper navigates away and its
/// grace elapses. The lifetime checkpoint measures exactly that.
public let storefrontDetailCogs = AsyncCogBox<ProductDetail, ProductID>(
  default: .empty,
  name: "storefront.detail"
) { c, id in
  let storefrontService = c[storefrontServiceCog]
  let productIndex = c[storefrontProductIndexCog]
  return .run { @concurrent in
    guard let product = productIndex[id] else { return .empty }
    return try await storefrontService.detail(for: product)
  }
}

// MARK: - Deep downstream

/// The shipping quote for the settled cart.
///
/// Deepest async in the graph: it depends on the discounted subtotal, which
/// depends on the promotion plan, which depends on every cart line, which
/// depends on every price ladder. A quantity change therefore replaces this
/// request, and the standard trace changes quantities rapidly on purpose so
/// that replacement is the behavior under measurement rather than an edge case.
public let storefrontShippingQuoteCog = AsyncCog<ShippingQuote>(
  default: .pending,
  name: "storefront.shippingQuote"
) { c in
  let storefrontService = c[storefrontServiceCog]
  let discountedSubtotal = c[storefrontDiscountedSubtotalCog]
  let shippingAddress = c[shippingAddressCog]
  let shippingMethod = c[shippingMethodCog]
  let cartLineIDs = c[storefrontCartLineIDsCog]
  return .run { @concurrent in
    // An empty cart is not a shipment. Quoting one would be a request no
    // storefront makes and a benchmark artifact nobody wants to explain.
    guard !cartLineIDs.isEmpty else { return .pending }
    return try await storefrontService.shippingQuote(
      subtotalCents: discountedSubtotal,
      address: shippingAddress,
      method: shippingMethod,
      lineCount: cartLineIDs.count
    )
  }
}

/// The tax quote for the settled cart.
///
/// A sibling of the shipping quote, and deliberately a separate request: the
/// two start together, complete in whichever order the driver chooses, and both
/// feed the order total — which is the fan-in shape a checkout screen actually
/// has.
public let storefrontTaxQuoteCog = AsyncCog<TaxQuote>(
  default: .pending,
  name: "storefront.taxQuote"
) { c in
  let storefrontService = c[storefrontServiceCog]
  let discountedSubtotal = c[storefrontDiscountedSubtotalCog]
  let shippingAddress = c[shippingAddressCog]
  let cartLineIDs = c[storefrontCartLineIDsCog]
  return .run { @concurrent in
    // Nothing in an empty cart is taxable, and asking is a request a real
    // checkout screen never sends.
    guard !cartLineIDs.isEmpty else { return .pending }
    return try await storefrontService.taxQuote(
      discountedSubtotalCents: discountedSubtotal,
      address: shippingAddress
    )
  }
}
