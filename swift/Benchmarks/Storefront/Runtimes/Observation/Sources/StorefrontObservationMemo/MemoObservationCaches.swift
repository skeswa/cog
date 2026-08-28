internal import StorefrontWorkload

// The four whole-screen caches this port keeps, and the granularity decision
// behind them.
//
// The port has seven caches: these four value types, two keyed dictionaries, and
// the async cell store. Cog declares 53 nodes. Matching them one for one would
// rebuild a dependency graph by hand instead of providing a fair comparison.
//
// Cache boundaries follow screen-level work, not each dependency edge. The
// search funnel is one cache because a query rebuilds it. Pricing uses one cell
// per product to avoid seventeen hand-written invalidation lists.
//
// Each type is an immutable snapshot rebuilt after a miss. It has no version,
// dirty bit, or dependency list. Named methods in
// `MemoObservationInvalidation.swift` clear the caches.

/// The accepted catalog, indexed for lookup.
///
/// Covers three of the Cog port's automatic declarations,
/// `storefrontCatalogProductsCog`, `storefrontCategoriesCog`, and
/// `storefrontProductIndexCog`, plus the category-name map the row builder
/// needs. One cache rather than four because they all have exactly one input,
/// the accepted catalog, so splitting them could never invalidate one without
/// the others.
struct MemoObservationCatalogIndexCache {
  /// The accepted catalog's products, in catalog order.
  let products: [Product]

  /// The accepted catalog's categories.
  let categories: [Category]

  /// Products by identifier.
  let productIndex: [ProductID: Product]

  /// Category names by identifier.
  ///
  /// A map rather than the linear search the Cog port's row builder performs.
  /// Not an optimization the comparison hides: it is part of the catalog cache
  /// this port declares, and building it is work this port does at catalog
  /// acceptance time that the Cog port does not.
  let categoryNames: [CategoryID: String]
}

/// One browse screen's worth of search funnel, from the raw query to sections.
///
/// Covers eight Cog declarations at once: the normalized query, its tokens, the
/// candidate set, per-candidate relevance scores, per-candidate filter
/// eligibility, the eligible set, the ranked order, and the section grouping.
///
/// They are one cache because every input that moves any of them moves nearly
/// all of them. A query keystroke re-tokenizes, re-intersects the postings,
/// rescores, re-ranks, and re-sections; a category chip re-filters, re-ranks,
/// and re-sections. Splitting the funnel into eight cells would let a sort-mode
/// change skip re-scoring, which is real, and which is exactly the granularity
/// a declared dependency graph gives away for free and a hand-written port pays
/// for in maintenance. This port declines to pay it, and the results table says
/// so.
struct MemoObservationSearchPipelineCache {
  /// The query, normalized once for everything downstream.
  let normalizedQuery: String

  /// The normalized query, split into tokens.
  let tokens: [String]

  /// Products the search index matched, ascending by identifier.
  let candidateIDs: [ProductID]

  /// Candidates that survive the filter bar.
  let eligibleIDs: [ProductID]

  /// Eligible products in presentation order.
  let rankedIDs: [ProductID]

  /// The ranked products, grouped into the sections the list renders.
  let sections: [StorefrontSection]
}

/// What the list has materialized, given a settled funnel and a row window.
///
/// Covers the visible set and the prefetch margin, plus the flattened section
/// order both are cut from. Separate from the funnel because scrolling changes
/// the window without changing a single thing above it, and scrolling is the
/// most frequent interaction in the workload.
struct MemoObservationWindowCache {
  /// The ranked products flattened through the section grouping.
  let flattened: [ProductID]

  /// The products inside the materialized window, in list order.
  let visibleIDs: [ProductID]

  /// The visible products plus the prefetch margin on either side.
  ///
  /// This, not the visible set, is what demands per-row asynchronous work.
  let prefetchIDs: [ProductID]

  /// Membership set behind ``prefetchIDs``.
  ///
  /// One line of bookkeeping a real team writes anyway, because "is this row on
  /// screen" is a question the screen already has to answer. It is what makes
  /// the port's central claim true: an invalidation for a product outside this
  /// set marks nothing dirty and starts no request.
  let demandedIDs: Set<ProductID>
}

/// The cart's expensive half: lines, subtotal, and the promotion plan.
///
/// Covers the cart's line identities, the per-line values, their sum, the
/// bounded promotion optimizer, and the discounted subtotal that the shipping
/// and tax quote identities are keyed on.
///
/// The order total and the checkout readiness are deliberately **not** here.
/// They are three additions and a handful of comparisons over this cache plus
/// two accepted quotes, so the port recomputes them on every cart render rather
/// than keeping a fifth field that an accepted quote would have to invalidate.
/// That is the cheaper choice in both directions: it saves the promotion
/// optimizer from re-running when a quote lands, and it saves a line of
/// invalidation bookkeeping.
struct MemoObservationCartCache {
  /// The cart's products, filtered to those still in the catalog with a
  /// positive quantity.
  let lineIDs: [ProductID]

  /// Every cart line, in cart order.
  let lines: [CartLine]

  /// The sum of every line's extended price.
  let subtotalCents: Int

  /// The best compatible set of promotions for this cart.
  let promotionPlan: PromotionPlan

  /// The subtotal after promotions, which the quote identities are keyed on.
  let discountedSubtotalCents: Int
}
