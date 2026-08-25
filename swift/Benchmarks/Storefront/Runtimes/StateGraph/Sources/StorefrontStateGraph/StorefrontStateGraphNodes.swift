internal import StateGraph
internal import StorefrontWorkload

// The Storefront derivation graph, expressed in swift-state-graph nodes.
//
// This file is the port's answer to `StorefrontState.swift`,
// `StorefrontAutomatic.swift`, and the *selector* half of
// `StorefrontAsync.swift` in
// `swift/Benchmarks/Storefront/Runtimes/CogRuntime/Sources/CogStorefront/`. Those
// three files are the specification of what is derived from what, and this one
// reproduces them node for node and dependency for dependency: the same
// sources, the same funnel, the same seventeen-stage pricing ladder per price
// book per product, the same per-row presentation values, the same cart chain,
// and the same short-circuit guards. Nothing is precomputed, nothing is
// flattened, and nothing knows the script.
//
// Three properties of swift-state-graph 0.28.0 shape every line below, and all
// three were measured rather than inferred; `API-NOTES.md` carries the probe
// output and the `file:line` citations.
//
// 1. `Computed` memoizes **only** through its `where Value: Equatable`
//    initializer. The non-memoizing overload sits in the same type with the
//    same argument labels and binds silently for a `Value` that is not
//    `Equatable`, which would turn that branch of the graph into a
//    recompute-on-read floor. Every node here is therefore built through
//    ``makeDerived(_:_:)``, whose `Value: Equatable` constraint makes the
//    memoizing overload the only applicable one, at one place a reviewer can
//    check. `StorefrontStateGraphMemoizationTests` proves the binding
//    behaviorally rather than trusting the argument.
// 2. `Stored` has *four* convenience initializers and the unconstrained one
//    notifies on every assignment. ``makeSource(_:_:)`` carries the same
//    `Value: Equatable` constraint for the same reason, so every source in this
//    port is equality-gated exactly like a Cog manual cog.
// 3. A `Computed` rule is `@Sendable` and may outlive the call that created it,
//    while this port is structurally MainActor-confined. Each rule therefore
//    captures this storage `unowned` and re-enters with
//    `MainActor.assumeIsolated`, which is the documented pattern
//    `StateGraphRuntimeComparisonGraph.automatic(_:)` already uses in
//    `swift/Benchmarks/Runner/Benchmarks/CogCore/`. The assumption is checked at
//    every rule invocation and that check is inside every number this runtime
//    reports, which is the honest place for it.
//
// Node names are `StaticString` (`Stored.swift:546`), so they cannot carry a
// key. One literal per node *kind* is used and identity lives in this class's
// dictionaries, which is also where the whole cost of keyed collections lives:
// 0.28.0 provides none.

/// Builds an equality-gated mutable source.
///
/// The `Value: Equatable` constraint is the entire point. `Stored`'s
/// unconstrained convenience initializer (`Stored.swift:645`) installs
/// `shouldNotify: { _, _ in true }` and notifies on *every* assignment; the
/// constrained one (`Stored.swift:667`) installs `{ $0 != $1 }`. Overload
/// resolution inside this function can only see `Value: Equatable`, so the
/// gated initializer is the only applicable one and no call site can silently
/// fall through to the ungated one. Writing a source that is already at its
/// current value then invalidates nothing, which is what
/// ``StorefrontRuntimeSemantics/browseRunsPerEqualWrite`` claims.
///
/// - Parameters:
///   - name: The node kind's literal name. Identity is the caller's dictionary
///     key, because `Stored`'s `name:` is a `StaticString` and cannot carry one.
///   - initialValue: The resting value, matching the Cog declaration's.
/// - Returns: An equality-gated source node.
func makeSource<Value: Equatable & Sendable>(
  _ name: StaticString,
  _ initialValue: Value
) -> Stored<Value> {
  Stored<Value>(name: name, wrappedValue: initialValue)
}

/// Builds a memoizing derived node.
///
/// The other half of the same argument, and the more dangerous half.
/// `Computed`'s two `rule:` initializers sit in the same type with the same
/// argument labels and differ only in a `where Value: Equatable` clause: the
/// constrained one (`StateGraph.swift:387`) installs `isEqual: { $0 == $1 }`
/// and the unconstrained one (`StateGraph.swift:357`) installs
/// `isEqual: { _, _ in false }`, which propagates to every dependent on every
/// recomputation and turns that branch of the graph into a recompute-on-read
/// floor. The library's doc comment on the memoizing one still describes the
/// non-memoizing behavior, so reading comments rather than bodies reaches the
/// opposite conclusion; `API-NOTES.md` §2.1 records both the bodies and the
/// probe output.
///
/// Every derived node in this port is built here, so the binding is decided in
/// one place a reviewer can check and `StorefrontStateGraphMemoizationTests`
/// proves it behaviorally against the pinned library rather than by argument.
///
/// - Parameters:
///   - name: The node kind's literal name.
///   - rule: The derivation. It takes no context because nothing in this port
///     uses `Computed.Context`'s environment or untracked-read facilities.
/// - Returns: A memoizing derived node.
func makeMemoizedComputed<Value: Equatable & Sendable>(
  _ name: StaticString,
  _ rule: @escaping @Sendable () -> Value
) -> Computed<Value> {
  Computed<Value>(name: name) { _ in rule() }
}

/// The Storefront's nodes: every source, every derived value, and every
/// asynchronous selector.
///
/// ## Identity and ownership
///
/// One instance per session, created and retained by
/// ``StateGraphStorefrontRuntime``. It owns every node: the keyless ones as
/// stored properties, the keyed ones in dictionaries it creates on first demand
/// and drops on release. Every rule captures it `unowned`, so the storage owns
/// the nodes and the nodes never own the storage — dropping this object drops
/// the whole graph, and dropping one dictionary entry drops exactly one
/// product's worth of it.
///
/// ## Isolation
///
/// MainActor-confined, because the storefront's graph is. Rules are
/// `@Sendable` closures the library may in principle invoke from anywhere;
/// this port only ever reads on the MainActor, and `MainActor.assumeIsolated`
/// at the rule boundary states and checks that.
///
/// ## Settlement ordering
///
/// Nothing here settles anything. Reads settle: `Computed.wrappedValue`
/// recomputes its whole upstream funnel synchronously on the reading thread
/// (`StateGraph.swift:437-504`), so the runtime's render step is both the
/// observation and the settlement barrier. There is no push and no scheduler in
/// this file.
///
/// `nonisolated deinit` per the repository convention: under
/// `.defaultIsolation(MainActor.self)` a synthesized deinit would ask the
/// concurrency runtime which executor it is on for every deallocation.
@MainActor
final class StorefrontStateGraphNodes {
  // MARK: - Injected world

  /// The world's size. Fixed for the session.
  let profile: StorefrontProfile

  /// The installed request boundary.
  ///
  /// A constant rather than a twelfth source, and this is a **disclosed
  /// deviation** from the Cog graph, which holds the service in
  /// `_storefrontServiceCog` so that installing it is one writable fact in one
  /// writable place. Two reasons. `StorefrontService` is not `Equatable`, so a
  /// `Stored<StorefrontService>` would bind the ungated initializer this port
  /// forbids everywhere else. And it is installed once, inside `make`, and
  /// never reassigned, so no invalidation can ever depend on it. The
  /// consequence is that the four rules that read the profile or the promotion
  /// fixtures read a constant here and a graph node in Cog; `README.md` records
  /// that as an advantage rather than hiding it.
  let service: StorefrontService

  // MARK: - Sources

  /// The raw text in the search field, exactly as typed.
  let searchQuery = makeSource("storefront.searchQuery", "")

  /// The category chip the shopper selected, or `nil` for all categories.
  let selectedCategory = makeSource("storefront.selectedCategory", CategoryID?.none)

  /// How results are ordered.
  let sortMode = makeSource("storefront.sortMode", SortMode.relevance)

  /// Whether out-of-stock products are hidden.
  let inStockOnly = makeSource("storefront.inStockOnly", false)

  /// The signed-in shopper, or `nil` before the account response is accepted.
  ///
  /// Deliberately a source rather than a read of the account slot, exactly as
  /// in Cog: signing out is a local action that must not wait on a request, and
  /// the port's account observer writes the accepted response here. One
  /// writable fact, one writable place.
  let signedInShopper = makeSource("storefront.shopper", Shopper?.none)

  /// The coupon the shopper typed, or `nil`.
  let coupon = makeSource("storefront.coupon", CouponCode?.none)

  /// Where the order ships.
  let shippingAddress = makeSource("storefront.shippingAddress", StorefrontFixtures.startingAddress)

  /// How the order ships.
  let shippingMethod = makeSource("storefront.shippingMethod", ShippingMethod.standard)

  /// The product whose detail screen is open, or `nil` on the browse screen.
  let selectedProduct = makeSource("storefront.selectedProduct", ProductID?.none)

  /// The window of rows the list has materialized.
  let rowWindow = makeSource("storefront.rowWindow", RowWindow(offset: 0, length: 0))

  /// The products in the cart, in the order they were added.
  let cartContents = makeSource("storefront.cartContents", [ProductID]())

  // MARK: - Keyed sources

  /// Whether each product is favorited.
  private var favoriteNodes: [ProductID: Stored<Bool>] = [:]

  /// How many of each product are in the cart.
  private var cartQuantityNodes: [ProductID: Stored<Int>] = [:]

  /// Which variant of each product is selected.
  private var selectedVariantNodes: [ProductID: Stored<Int>] = [:]

  /// How recently each product was viewed; zero means never.
  private var recentlyViewedRankNodes: [ProductID: Stored<Int>] = [:]

  /// Which inventory generation each product is asking the service for.
  ///
  /// Keyed rather than one global epoch, and that is the whole point of the
  /// inventory burst: a burst advances new generations for exactly the products
  /// it touched, in one transaction, so a checkpoint can prove the offscreen
  /// half invalidated nothing on screen.
  private var inventoryGenerationNodes: [ProductID: Stored<Int>] = [:]

  // MARK: - Accepted asynchronous values

  /// The accepted catalog.
  ///
  /// The value alone. The generation and the in-flight plan live in the
  /// runtime's slot table, never in a node, so that advancing a generation
  /// invalidates nothing that renders.
  let catalog = makeSource("storefront.catalog", CatalogSnapshot.empty)

  /// How many genuinely different catalogs have been accepted.
  ///
  /// The cheap stand-in for "the catalog changed" inside an asynchronous plan.
  /// A Cog selector that reads `catalogProducts` re-selects when the products
  /// change; a plan that carried the `[Product]` array would have to compare a
  /// thousand products on every poll of every demanded slot to learn the same
  /// thing. The runtime bumps this exactly when it publishes a catalog that
  /// differs from the one already accepted — one comparison per response
  /// instead of tens of thousands per session.
  let catalogRevision = makeSource("storefront.catalogRevision", 0)

  /// The accepted account response, or `nil` before one lands.
  ///
  /// Read only by the port's account observer, exactly as `storefrontAccountCog`
  /// is read only by Cog's account watcher.
  let account = makeSource("storefront.account", Shopper?.none)

  /// The accepted inverted search index.
  let searchIndex = makeSource("storefront.searchIndex", StorefrontKernels.SearchIndex.empty)

  /// The accepted suggestions for the current query.
  let suggestions = makeSource("storefront.suggestions", [String]())

  /// The accepted recommendations.
  let recommendations = makeSource("storefront.recommendations", [ProductID]())

  /// The accepted shipping quote.
  let shippingQuote = makeSource("storefront.shippingQuote", ShippingQuote.pending)

  /// The accepted tax quote.
  let taxQuote = makeSource("storefront.taxQuote", TaxQuote.pending)

  /// Live inventory per product, created on first demand.
  private var inventoryNodes: [ProductID: Stored<InventoryReading>] = [:]

  /// The personalized offer per product, created on first demand.
  private var offerNodes: [ProductID: Stored<PersonalizedOffer>] = [:]

  /// The detail payload per product, created on first demand.
  private var detailNodes: [ProductID: Stored<ProductDetail>] = [:]

  // MARK: - Derived values

  /// The search text, normalized once for everything downstream.
  ///
  /// Equality-gated, and that gate does real work: typing a trailing space, or
  /// changing case, produces the same normalization, so the search index, the
  /// suggestion plan, and every candidate set stay exactly where they were.
  lazy var normalizedQuery: Computed<String> = makeDerived("storefront.normalizedQuery") {
    StorefrontKernels.normalize($0.searchQuery.wrappedValue)
  }

  /// The normalized query, split into tokens.
  lazy var queryTokens: Computed<[String]> = makeDerived("storefront.queryTokens") {
    StorefrontKernels.tokenize($0.normalizedQuery.wrappedValue)
  }

  /// The accepted catalog's products.
  ///
  /// A value read of the catalog slot, so a reload that returns an equal
  /// catalog leaves the entire browse graph alone.
  lazy var catalogProducts: Computed<[Product]> = makeDerived("storefront.catalogProducts") {
    $0.catalog.wrappedValue.products
  }

  /// The accepted catalog's categories, in identifier order.
  lazy var categories: Computed<[StorefrontWorkload.Category]> = makeDerived(
    "storefront.categories"
  ) {
    $0.catalog.wrappedValue.categories
  }

  /// Products by identifier.
  ///
  /// The lookup every keyed rule goes through, so a product's fields are
  /// resolved once per catalog rather than once per row per settlement.
  lazy var productIndex: Computed<[ProductID: Product]> = makeDerived("storefront.productIndex") {
    Dictionary(uniqueKeysWithValues: $0.catalogProducts.wrappedValue.map { ($0.id, $0) })
  }

  /// Products the search index matched, ascending by identifier.
  lazy var searchCandidateIDs: Computed<[ProductID]> = makeDerived("storefront.searchCandidates") {
    nodes in
    let ordinals = StorefrontKernels.candidates(
      in: nodes.searchIndex.wrappedValue,
      tokens: nodes.queryTokens.wrappedValue,
      productCount: nodes.catalogProducts.wrappedValue.count
    )
    return ordinals.map { ProductID($0) }
  }

  /// Candidates that survive the filter bar.
  lazy var eligibleProductIDs: Computed<[ProductID]> = makeDerived("storefront.eligibleProducts") {
    nodes in
    nodes.searchCandidateIDs.wrappedValue.filter { nodes.filterEligibility($0).wrappedValue }
  }

  /// Eligible products in presentation order.
  ///
  /// Price ordering uses the catalog's list price, not the effective price and
  /// not the selected variant's adjusted one — the same product decision Cog's
  /// declaration records, and for the same reason: sorting a thousand products
  /// by a personalized price would demand a personalized offer and a live
  /// inventory reading for every one of them.
  lazy var rankedProductIDs: Computed<[ProductID]> = makeDerived("storefront.rankedProducts") {
    nodes in
    let eligible = nodes.eligibleProductIDs.wrappedValue
    let index = nodes.productIndex.wrappedValue
    let products = nodes.catalogProducts.wrappedValue

    var scores: [Int: Int] = [:]
    var prices: [Int: Int] = [:]
    scores.reserveCapacity(eligible.count)
    prices.reserveCapacity(eligible.count)
    for id in eligible {
      scores[id.raw] = nodes.searchScore(id).wrappedValue
      guard let product = index[id] else { continue }
      prices[id.raw] = product.listPriceCents
    }

    return StorefrontKernels.rank(
      candidates: eligible.map(\.raw),
      products: products,
      scores: scores,
      prices: prices,
      mode: nodes.sortMode.wrappedValue
    )
  }

  /// The ranked products, grouped into the sections the browse list renders.
  lazy var sections: Computed<[StorefrontSection]> = makeDerived("storefront.sections") { nodes in
    let ranked = nodes.rankedProductIDs.wrappedValue
    let index = nodes.productIndex.wrappedValue
    let categoryNames = Dictionary(
      uniqueKeysWithValues: nodes.categories.wrappedValue.map { ($0.id, $0.name) }
    )

    let topBandCount = min(ranked.count, 12)
    var sections: [StorefrontSection] = []
    if topBandCount > 0 {
      sections.append(
        StorefrontSection(
          category: nil,
          title: "Best matches",
          productIDs: Array(ranked.prefix(topBandCount))
        )
      )
    }

    var order: [CategoryID] = []
    var grouped: [CategoryID: [ProductID]] = [:]
    for id in ranked.dropFirst(topBandCount) {
      guard let product = index[id] else { continue }
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
  lazy var visibleProductIDs: Computed<[ProductID]> = makeDerived("storefront.visibleProducts") {
    nodes in
    let flattened = nodes.sections.wrappedValue.flatMap(\.productIDs)
    let window = nodes.rowWindow.wrappedValue
    guard window.length > 0, window.offset < flattened.count else { return [] }
    let end = min(flattened.count, window.offset + window.length)
    return Array(flattened[window.offset..<end])
  }

  /// The visible products plus the prefetch margin on either side.
  ///
  /// This — not the visible set — is what demands per-row asynchronous work,
  /// which is why scrolling one row does not start a request storm.
  lazy var prefetchProductIDs: Computed<[ProductID]> = makeDerived("storefront.prefetchProducts") {
    nodes in
    let flattened = nodes.sections.wrappedValue.flatMap(\.productIDs)
    let window = nodes.rowWindow.wrappedValue
    let margin = nodes.service.profile.prefetchMargin
    guard window.length > 0, !flattened.isEmpty else { return [] }
    let start = max(0, window.offset - margin)
    let end = min(flattened.count, window.offset + window.length + margin)
    guard start < end else { return [] }
    return Array(flattened[start..<end])
  }

  /// The cart's products, filtered to the ones still in the catalog with a
  /// positive quantity.
  lazy var cartLineIDs: Computed<[ProductID]> = makeDerived("storefront.cartLineIDs") { nodes in
    let index = nodes.productIndex.wrappedValue
    return nodes.cartContents.wrappedValue.filter { id in
      guard index[id] != nil else { return false }
      return nodes.cartQuantity(id).wrappedValue > 0
    }
  }

  /// Every cart line, in cart order.
  lazy var cartLines: Computed<[CartLine]> = makeDerived("storefront.cartLines") { nodes in
    nodes.cartLineIDs.wrappedValue.map { nodes.cartLine($0).wrappedValue }
  }

  /// The sum of every line's extended price.
  lazy var cartSubtotal: Computed<Int> = makeDerived("storefront.cartSubtotal") { nodes in
    nodes.cartLines.wrappedValue.reduce(0) { $0 + $1.extendedCents }
  }

  /// The best compatible set of promotions for the current cart.
  ///
  /// The bounded dynamic-programming pass, run synchronously because a shopper
  /// who types a coupon expects the total to move on the same frame.
  lazy var promotionPlan: Computed<PromotionPlan> = makeDerived("storefront.promotionPlan") {
    nodes in
    let lines = nodes.cartLines.wrappedValue
    guard !lines.isEmpty else { return .none }
    let categories = nodes.productIndex.wrappedValue.mapValues(\.category)
    return StorefrontKernels.selectPromotions(
      lines: lines,
      promotions: StorefrontFixtures.promotions(for: nodes.service.profile),
      categories: categories,
      couponID: nodes.coupon.wrappedValue?.raw
    )
  }

  /// The subtotal after promotions.
  ///
  /// Equality-gated, and it is the gate that matters most in the whole graph:
  /// the shipping and tax quote plans are downstream of it, so a cart change
  /// that leaves the discounted subtotal alone starts no request at all.
  lazy var discountedSubtotal: Computed<Int> = makeDerived("storefront.discountedSubtotal") {
    nodes in
    max(0, nodes.cartSubtotal.wrappedValue - nodes.promotionPlan.wrappedValue.discountCents)
  }

  /// The cart's money, fully broken down.
  lazy var orderTotal: Computed<OrderTotal> = makeDerived("storefront.orderTotal") { nodes in
    OrderTotal(
      subtotalCents: nodes.cartSubtotal.wrappedValue,
      discountCents: nodes.promotionPlan.wrappedValue.discountCents,
      discountedSubtotalCents: nodes.discountedSubtotal.wrappedValue,
      taxCents: nodes.taxQuote.wrappedValue.taxCents,
      shippingCents: nodes.shippingQuote.wrappedValue.costCents
    )
  }

  /// Whether the cart can be checked out, and why not when it cannot.
  lazy var checkoutReadiness: Computed<CheckoutReadiness> = makeDerived(
    "storefront.checkoutReadiness"
  ) { nodes -> CheckoutReadiness in
    var blockers: [String] = []
    let lines = nodes.cartLines.wrappedValue
    if lines.isEmpty { blockers.append("The cart is empty.") }
    if lines.contains(where: { !$0.inStock }) {
      blockers.append("Some items are not available in the quantity requested.")
    }
    if nodes.signedInShopper.wrappedValue == nil { blockers.append("Sign in to check out.") }
    if nodes.shippingQuote.wrappedValue.estimatedDays == 0 {
      blockers.append("Waiting for a shipping quote.")
    }
    return CheckoutReadiness(isReady: blockers.isEmpty, blockers: blockers)
  }

  // MARK: - Keyed derived values

  /// One product's relevance score for the current query.
  private var searchScoreNodes: [ProductID: Computed<Int>] = [:]

  /// Whether one product survives the filter bar.
  private var filterEligibilityNodes: [ProductID: Computed<Bool>] = [:]

  /// One node of the pricing pipeline, keyed by product, price book, and stage.
  private var pricingStageNodes: [StorefrontPricing.StageKey: Computed<Int>] = [:]

  /// One product's effective price.
  private var effectivePriceNodes: [ProductID: Computed<Int>] = [:]

  /// Units available for one product's selected variant.
  private var availabilityNodes: [ProductID: Computed<Int>] = [:]

  /// The badges one product's row shows.
  private var badgesNodes: [ProductID: Computed<ProductBadges>] = [:]

  /// Everything one product row renders.
  private var productRowNodes: [ProductID: Computed<ProductRow>] = [:]

  /// One cart line.
  private var cartLineNodes: [ProductID: Computed<CartLine>] = [:]

  // MARK: - Asynchronous selectors

  /// What the search index slot would ask for.
  lazy var searchIndexPlan: Computed<StorefrontStateGraphPlan> = makeDerived(
    "storefront.plan.searchIndex"
  ) { nodes -> StorefrontStateGraphPlan in
    .searchIndex(catalogRevision: nodes.catalogRevision.wrappedValue)
  }

  /// What the suggestion slot would ask for.
  ///
  /// Keyed off the *normalized* query, exactly as Cog's selector is, so two
  /// keystrokes that normalize the same way do not start two generations.
  lazy var suggestionsPlan: Computed<StorefrontStateGraphPlan> = makeDerived(
    "storefront.plan.suggestions"
  ) { nodes -> StorefrontStateGraphPlan in
    let query = nodes.normalizedQuery.wrappedValue
    guard !query.isEmpty else { return .resting }
    return .suggestions(query: query, catalogRevision: nodes.catalogRevision.wrappedValue)
  }

  /// What the recommendation slot would ask for.
  lazy var recommendationsPlan: Computed<StorefrontStateGraphPlan> = makeDerived(
    "storefront.plan.recommendations"
  ) { nodes -> StorefrontStateGraphPlan in
    guard let shopper = nodes.signedInShopper.wrappedValue else { return .resting }
    return .recommendations(
      accountID: shopper.accountID,
      catalogRevision: nodes.catalogRevision.wrappedValue
    )
  }

  /// What the shipping quote slot would ask for.
  lazy var shippingQuotePlan: Computed<StorefrontStateGraphPlan> = makeDerived(
    "storefront.plan.shippingQuote"
  ) { nodes -> StorefrontStateGraphPlan in
    let lineIDs = nodes.cartLineIDs.wrappedValue
    guard !lineIDs.isEmpty else { return .resting }
    return .shippingQuote(
      subtotalCents: nodes.discountedSubtotal.wrappedValue,
      address: nodes.shippingAddress.wrappedValue,
      method: nodes.shippingMethod.wrappedValue,
      lineCount: lineIDs.count
    )
  }

  /// What the tax quote slot would ask for.
  lazy var taxQuotePlan: Computed<StorefrontStateGraphPlan> = makeDerived(
    "storefront.plan.taxQuote"
  ) { nodes -> StorefrontStateGraphPlan in
    guard !nodes.cartLineIDs.wrappedValue.isEmpty else { return .resting }
    return .taxQuote(
      subtotalCents: nodes.discountedSubtotal.wrappedValue,
      address: nodes.shippingAddress.wrappedValue
    )
  }

  /// What one product's inventory slot would ask for.
  private var inventoryPlanNodes: [ProductID: Computed<StorefrontStateGraphPlan>] = [:]

  /// What one product's offer slot would ask for.
  private var offerPlanNodes: [ProductID: Computed<StorefrontStateGraphPlan>] = [:]

  /// What one product's detail slot would ask for.
  private var detailPlanNodes: [ProductID: Computed<StorefrontStateGraphPlan>] = [:]

  // MARK: - Release bookkeeping

  /// Every product this session has materialized per-product nodes for.
  ///
  /// The candidate set the runtime's lifetime sweep walks. It is the port's own
  /// bookkeeping because the release policy is the port's own: swift-state-graph
  /// has no lifetime model, and a node lives exactly as long as the dictionary
  /// entry holding it.
  private(set) var materializedProductIDs: Set<ProductID> = []

  /// Creates the graph with the world it serves and the window it starts at.
  ///
  /// The starting window is written here rather than by a later verb so that it
  /// has settled before anything observes, which is what
  /// `StorefrontMechanism.operate` does for Cog and what makes the bootstrap
  /// phase's browse-run count a claim about registration rather than a race.
  ///
  /// - Parameters:
  ///   - profile: The world's size.
  ///   - service: The installed request boundary.
  ///   - initialWindow: The row window the list starts at.
  init(profile: StorefrontProfile, service: StorefrontService, initialWindow: RowWindow) {
    self.profile = profile
    self.service = service
    rowWindow.wrappedValue = initialWindow
  }

  // MARK: - Node construction

  /// Builds a memoizing derived node whose rule re-enters the MainActor.
  ///
  /// Two jobs, and neither is the memoization decision: that one belongs to
  /// ``makeMemoizedComputed(_:_:)``, which this forwards to and which every
  /// derived node in the port therefore goes through. What happens here is the
  /// crossing between the library's world and this port's. A `Computed` rule is
  /// `@Sendable` and may outlive the call that created it, so the storage is
  /// captured `unowned` — the storage owns the nodes, never the reverse — and
  /// `MainActor.assumeIsolated` states and checks the synchronous invariant
  /// that this port only ever reads on the MainActor. The rule receives the
  /// storage as an argument rather than closing over `self` so that both of
  /// those happen in one place instead of in twenty-six rules.
  ///
  /// - Parameters:
  ///   - name: The node kind's literal name.
  ///   - rule: The derivation, which reads other nodes through the storage it
  ///     is handed. It receives the storage rather than closing over `self` so
  ///     that the `unowned` capture and the isolation assumption happen in one
  ///     place instead of in every rule.
  /// - Returns: A memoizing derived node.
  private func makeDerived<Value: Equatable & Sendable>(
    _ name: StaticString,
    _ rule: @escaping @Sendable @MainActor (StorefrontStateGraphNodes) -> Value
  ) -> Computed<Value> {
    makeMemoizedComputed(name) { [unowned self] in
      MainActor.assumeIsolated { rule(self) }
    }
  }

  // MARK: - Keyed source accessors

  /// Whether one product is favorited.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The source, created at its resting value on first demand.
  func favorite(_ id: ProductID) -> Stored<Bool> {
    if let node = favoriteNodes[id] { return node }
    let node = makeSource("storefront.favorite", false)
    favoriteNodes[id] = node
    return node
  }

  /// How many of one product are in the cart.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The source, created at its resting value on first demand.
  func cartQuantity(_ id: ProductID) -> Stored<Int> {
    if let node = cartQuantityNodes[id] { return node }
    let node = makeSource("storefront.cartQuantity", 0)
    cartQuantityNodes[id] = node
    return node
  }

  /// Which variant of one product is selected.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The source, created at its resting value on first demand.
  func selectedVariant(_ id: ProductID) -> Stored<Int> {
    if let node = selectedVariantNodes[id] { return node }
    let node = makeSource("storefront.selectedVariant", 0)
    selectedVariantNodes[id] = node
    return node
  }

  /// How recently one product was viewed.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The source, created at its resting value on first demand.
  func recentlyViewedRank(_ id: ProductID) -> Stored<Int> {
    if let node = recentlyViewedRankNodes[id] { return node }
    let node = makeSource("storefront.recentlyViewedRank", 0)
    recentlyViewedRankNodes[id] = node
    return node
  }

  /// Which inventory generation one product is asking the service for.
  ///
  /// Never released. A generation is the shopper's — or the warehouse feed's —
  /// own write, and a lifetime sweep that reset it would make a product ask for
  /// a reading it has already been told is stale.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The source, created at its resting value on first demand.
  func inventoryGeneration(_ id: ProductID) -> Stored<Int> {
    if let node = inventoryGenerationNodes[id] { return node }
    let node = makeSource("storefront.inventoryGeneration", 0)
    inventoryGenerationNodes[id] = node
    return node
  }

  // MARK: - Keyed asynchronous value accessors

  /// The accepted inventory reading for one product.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The value node, resting at ``InventoryReading/unknown``.
  func inventory(_ id: ProductID) -> Stored<InventoryReading> {
    if let node = inventoryNodes[id] { return node }
    let node = makeSource("storefront.inventory", InventoryReading.unknown)
    inventoryNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  /// The accepted personalized offer for one product.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The value node, resting at ``PersonalizedOffer/none``.
  func offer(_ id: ProductID) -> Stored<PersonalizedOffer> {
    if let node = offerNodes[id] { return node }
    let node = makeSource("storefront.offer", PersonalizedOffer.none)
    offerNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  /// The accepted detail payload for one product.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The value node, resting at ``ProductDetail/empty``.
  func detail(_ id: ProductID) -> Stored<ProductDetail> {
    if let node = detailNodes[id] { return node }
    let node = makeSource("storefront.detail", ProductDetail.empty)
    detailNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  // MARK: - Keyed derived accessors

  /// One product's relevance score for the current query.
  ///
  /// Deliberately does **not** read this session's view history, matching Cog's
  /// declaration: boosting a product the shopper just looked at would make
  /// opening one re-rank the whole result set while they are looking at it.
  ///
  /// Never released. The funnel reads a score for every candidate on every
  /// recomputation, so a score is demanded for as long as the browse screen is
  /// held, and sweeping one away would only make the next settlement rebuild it.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The derived node.
  func searchScore(_ id: ProductID) -> Computed<Int> {
    if let node = searchScoreNodes[id] { return node }
    let node = makeDerived("storefront.searchScore") { nodes in
      guard let product = nodes.productIndex.wrappedValue[id] else { return 0 }
      return StorefrontKernels.relevanceScore(
        product: product,
        tokens: nodes.queryTokens.wrappedValue
      )
    }
    searchScoreNodes[id] = node
    return node
  }

  /// Whether one product survives the filter bar.
  ///
  /// Two deliberate omissions, both copied from Cog's declaration because they
  /// are the difference between a workload that measures a graph and one that
  /// measures a design mistake: it reads the *catalog's* stock rather than live
  /// inventory, so flipping the switch does not demand an inventory request for
  /// the whole catalog; and it asks whether *any* variant is stocked rather
  /// than the selected one, so selecting a variant does not re-rank the list.
  ///
  /// Never released, for the same reason as ``searchScore(_:)``.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The derived node.
  func filterEligibility(_ id: ProductID) -> Computed<Bool> {
    if let node = filterEligibilityNodes[id] { return node }
    let node = makeDerived("storefront.filterEligibility") { nodes in
      guard let product = nodes.productIndex.wrappedValue[id] else { return false }
      if let category = nodes.selectedCategory.wrappedValue, product.category != category {
        return false
      }
      guard nodes.inStockOnly.wrappedValue else { return true }
      return product.variants.contains { $0.catalogStock > 0 }
    }
    filterEligibilityNodes[id] = node
    return node
  }

  /// One node of the pricing pipeline.
  ///
  /// Stage zero is the price book's base; stage `n` applies
  /// ``StorefrontPricing/ladder``'s `n - 1`th policy to stage `n - 1`. The
  /// recursion is what makes one accessor a seventeen-node chain per product
  /// per book, and the `switch` is what makes each node depend on only the
  /// inputs its own policy reads — so changing the coupon invalidates the
  /// coupon stage and everything below it, and nothing above it. The full
  /// granularity is reproduced because swift-state-graph genuinely provides it;
  /// collapsing the ladder would understate the library.
  ///
  /// - Parameter key: The product, book, and stage.
  /// - Returns: The derived node.
  func pricingStage(_ key: StorefrontPricing.StageKey) -> Computed<Int> {
    if let node = pricingStageNodes[key] { return node }
    let node = makeDerived("storefront.pricingStage") { nodes in
      nodes.computePricingStage(key)
    }
    pricingStageNodes[key] = node
    materializedProductIDs.insert(key.productID)
    return node
  }

  /// One product's effective price: the best price book it qualifies for.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The derived node.
  func effectivePrice(_ id: ProductID) -> Computed<Int> {
    if let node = effectivePriceNodes[id] { return node }
    let node = makeDerived("storefront.effectivePrice") { nodes in
      let profile = nodes.service.profile
      guard let product = nodes.productIndex.wrappedValue[id] else { return 0 }
      let tier = nodes.signedInShopper.wrappedValue?.tier ?? .guest
      let stage = profile.pricingPolicyCount

      var best: Int?
      for book in StorefrontPricing.PriceBook.allCases.prefix(profile.priceBookCount) {
        guard book.qualifies(for: tier) else { continue }
        let key = StorefrontPricing.StageKey(productID: id, book: book, stage: stage)
        let price = nodes.pricingStage(key).wrappedValue
        best = best.map { min($0, price) } ?? price
      }
      return best ?? product.listPriceCents
    }
    effectivePriceNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  /// Units available for one product's selected variant.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The derived node.
  func availability(_ id: ProductID) -> Computed<Int> {
    if let node = availabilityNodes[id] { return node }
    let node = makeDerived("storefront.availability") { nodes in
      nodes.inventory(id).wrappedValue.units(
        forVariant: nodes.selectedVariant(id).wrappedValue
      )
    }
    availabilityNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  /// The badges one product's row shows.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The derived node.
  func badges(_ id: ProductID) -> Computed<ProductBadges> {
    if let node = badgesNodes[id] { return node }
    let node = makeDerived("storefront.badges") { nodes -> ProductBadges in
      guard let product = nodes.productIndex.wrappedValue[id] else { return [] }
      var badges: ProductBadges = []

      if nodes.effectivePrice(id).wrappedValue < product.listPriceCents { badges.insert(.onSale) }

      let availability = nodes.availability(id).wrappedValue
      let inventory = nodes.inventory(id).wrappedValue
      if availability == 0 && !inventory.restockable {
        badges.insert(.soldOut)
      } else if availability > 0 && availability <= 3 {
        badges.insert(.lowStock)
      }

      if nodes.offer(id).wrappedValue.discountBasisPoints > 0 { badges.insert(.offer) }
      if nodes.favorite(id).wrappedValue { badges.insert(.favorite) }
      if nodes.recentlyViewedRank(id).wrappedValue > 0 { badges.insert(.recentlyViewed) }
      if nodes.cartQuantity(id).wrappedValue > 0 { badges.insert(.inCart) }

      return badges
    }
    badgesNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  /// Everything one product row renders.
  ///
  /// A row reads this and nothing else, so an inventory burst that changes an
  /// offscreen product changes no row that is on screen.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The derived node.
  func productRow(_ id: ProductID) -> Computed<ProductRow> {
    if let node = productRowNodes[id] { return node }
    let node = makeDerived("storefront.productRow") { nodes in
      guard let product = nodes.productIndex.wrappedValue[id] else {
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
        nodes.categories.wrappedValue.first { $0.id == product.category }?.name
        ?? "Category \(product.category.raw)"
      return ProductRow(
        productID: id,
        name: product.name,
        categoryName: categoryName,
        priceCents: nodes.effectivePrice(id).wrappedValue,
        listPriceCents: product.listPriceCents,
        availableUnits: nodes.availability(id).wrappedValue,
        badges: nodes.badges(id).wrappedValue,
        cartQuantity: nodes.cartQuantity(id).wrappedValue
      )
    }
    productRowNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  /// One cart line.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The derived node.
  func cartLine(_ id: ProductID) -> Computed<CartLine> {
    if let node = cartLineNodes[id] { return node }
    let node = makeDerived("storefront.cartLine") { nodes in
      let quantity = nodes.cartQuantity(id).wrappedValue
      let variant = nodes.selectedVariant(id).wrappedValue
      guard let product = nodes.productIndex.wrappedValue[id] else {
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
        unitPriceCents: nodes.effectivePrice(id).wrappedValue,
        inStock: nodes.availability(id).wrappedValue >= quantity
      )
    }
    cartLineNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  // MARK: - Keyed asynchronous selectors

  /// What one product's inventory slot would ask for.
  ///
  /// Reads the keyed generation, so a burst that touches this product changes
  /// exactly this plan and no other.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The selector node.
  func inventoryPlan(_ id: ProductID) -> Computed<StorefrontStateGraphPlan> {
    if let node = inventoryPlanNodes[id] { return node }
    let node = makeDerived("storefront.plan.inventory") { nodes -> StorefrontStateGraphPlan in
      .inventory(id: id, generation: nodes.inventoryGeneration(id).wrappedValue)
    }
    inventoryPlanNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  /// What one product's offer slot would ask for.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The selector node.
  func offerPlan(_ id: ProductID) -> Computed<StorefrontStateGraphPlan> {
    if let node = offerPlanNodes[id] { return node }
    let node = makeDerived("storefront.plan.offer") { nodes -> StorefrontStateGraphPlan in
      guard let shopper = nodes.signedInShopper.wrappedValue else { return .resting }
      return .offer(id: id, accountID: shopper.accountID)
    }
    offerPlanNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  /// What one product's detail slot would ask for.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The selector node.
  func detailPlan(_ id: ProductID) -> Computed<StorefrontStateGraphPlan> {
    if let node = detailPlanNodes[id] { return node }
    let node = makeDerived("storefront.plan.detail") { nodes -> StorefrontStateGraphPlan in
      guard nodes.productIndex.wrappedValue[id] != nil else { return .resting }
      return .detail(id: id, catalogRevision: nodes.catalogRevision.wrappedValue)
    }
    detailPlanNodes[id] = node
    materializedProductIDs.insert(id)
    return node
  }

  // MARK: - Release

  /// Drops every releasable node belonging to one product.
  ///
  /// swift-state-graph has no lifetime model, so a node lives exactly as long
  /// as the dictionary entry holding it and this method is the whole release
  /// mechanism. Edge cleanup is the library's: `Edge` holds both endpoints
  /// weakly and `Computed.deinit` unhooks itself from its upstreams and marks
  /// its dependents dirty (`StateGraph.swift:406-422`), which probe `c` in
  /// `API-NOTES.md` confirms by watching a shared source's outgoing-edge count
  /// fall as an entry is dropped.
  ///
  /// Sources are kept. A favorite flag, a cart quantity, a selected variant, a
  /// recency rank, and an inventory generation are writes somebody made; a
  /// sweep that reset them would not be releasing a cache, it would be losing
  /// data. What goes is the derived and asynchronous state that can be rebuilt
  /// by asking again — which is exactly what the teardown phase's release proof
  /// demands: the released row has to ask the service a second time.
  ///
  /// The funnel-wide keyed nodes are kept too, for a different reason:
  /// ``searchScore(_:)`` and ``filterEligibility(_:)`` are read for every
  /// candidate every time the ranking recomputes, so they are demanded for as
  /// long as the browse screen is held and dropping one would only make the
  /// next settlement rebuild it.
  ///
  /// - Parameter id: The product to release.
  func release(_ id: ProductID) {
    for stage in 0...StorefrontPricing.ladder.count {
      for book in StorefrontPricing.PriceBook.allCases {
        pricingStageNodes.removeValue(
          forKey: StorefrontPricing.StageKey(productID: id, book: book, stage: stage)
        )
      }
    }
    effectivePriceNodes.removeValue(forKey: id)
    availabilityNodes.removeValue(forKey: id)
    badgesNodes.removeValue(forKey: id)
    productRowNodes.removeValue(forKey: id)
    cartLineNodes.removeValue(forKey: id)
    inventoryNodes.removeValue(forKey: id)
    offerNodes.removeValue(forKey: id)
    detailNodes.removeValue(forKey: id)
    inventoryPlanNodes.removeValue(forKey: id)
    offerPlanNodes.removeValue(forKey: id)
    detailPlanNodes.removeValue(forKey: id)
    materializedProductIDs.remove(id)
  }

  // MARK: - Rules that are too long to inline

  /// One stage of the pricing ladder.
  ///
  /// Split out of ``pricingStage(_:)`` because a sixteen-case `switch` inside a
  /// closure inside an accessor is unreadable, not because it is a different
  /// kind of code: this *is* the rule, and every case reads exactly the inputs
  /// the matching Cog declaration reads.
  ///
  /// - Parameter key: The product, book, and stage.
  /// - Returns: The price in cents after this stage.
  private func computePricingStage(_ key: StorefrontPricing.StageKey) -> Int {
    let index = productIndex.wrappedValue
    guard let policy = key.policy, let previous = key.previous else {
      guard let product = index[key.productID] else { return 0 }
      return StorefrontPricing.basePrice(
        product: product,
        book: key.book,
        variantIndex: clampedVariantIndex(for: key.productID, in: product)
      )
    }
    let cents = pricingStage(previous).wrappedValue

    switch policy {
    case .regionalMarket:
      return StorefrontPricing.regionalMarket(
        cents,
        market: shippingAddress.wrappedValue.market
      )
    case .membershipTier:
      return StorefrontPricing.membershipTier(
        cents,
        tier: signedInShopper.wrappedValue?.tier ?? .guest
      )
    case .categoryCampaign:
      guard let product = index[key.productID] else { return 0 }
      return StorefrontPricing.categoryCampaign(cents, category: product.category)
    case .couponCode:
      guard let product = index[key.productID] else { return 0 }
      return StorefrontPricing.couponCode(
        cents,
        coupon: coupon.wrappedValue,
        category: product.category,
        promotions: StorefrontFixtures.promotions(for: service.profile)
      )
    case .bundleQuantity:
      return StorefrontPricing.bundleQuantity(
        cents,
        cartQuantity: cartQuantity(key.productID).wrappedValue
      )
    case .inventoryMarkdown:
      guard let product = index[key.productID] else { return 0 }
      return StorefrontPricing.inventoryMarkdown(
        cents,
        availableUnits: inventory(key.productID).wrappedValue.units(
          forVariant: clampedVariantIndex(for: key.productID, in: product)
        )
      )
    case .clearance:
      guard let product = index[key.productID] else { return 0 }
      let reading = inventory(key.productID).wrappedValue
      return StorefrontPricing.clearance(
        cents,
        restockable: reading.restockable,
        availableUnits: reading.units(
          forVariant: clampedVariantIndex(for: key.productID, in: product)
        )
      )
    case .loyaltyBurn:
      return StorefrontPricing.loyaltyBurn(
        cents,
        loyaltyPoints: signedInShopper.wrappedValue?.loyaltyPoints ?? 0
      )
    case .variantPremium:
      guard let product = index[key.productID] else { return 0 }
      let variantIndex = clampedVariantIndex(for: key.productID, in: product)
      let delta = product.variants.isEmpty ? 0 : product.variants[variantIndex].priceDeltaCents
      return StorefrontPricing.variantPremium(cents, delta: delta)
    case .ecoLevy:
      guard let product = index[key.productID] else { return 0 }
      return StorefrontPricing.ecoLevy(cents, category: product.category)
    case .shippingSubsidy:
      return StorefrontPricing.shippingSubsidy(cents, method: shippingMethod.wrappedValue)
    case .competitorMatch:
      guard let product = index[key.productID] else { return 0 }
      return StorefrontPricing.competitorMatch(cents, product: product)
    case .recentlyViewedNudge:
      return StorefrontPricing.recentlyViewedNudge(
        cents,
        viewRank: recentlyViewedRank(key.productID).wrappedValue
      )
    case .personalizedOffer:
      return StorefrontPricing.personalizedOffer(
        cents,
        offer: offer(key.productID).wrappedValue
      )
    case .priceFloor:
      guard let product = index[key.productID] else { return 0 }
      return StorefrontPricing.priceFloor(cents, product: product)
    case .charmRounding:
      return StorefrontPricing.charmRounding(cents)
    }
  }

  /// The selected variant, clamped exactly where ``StorefrontPricing`` clamps.
  ///
  /// The availability computation is deliberately left unclamped, matching Cog:
  /// a variant index past the end means no units, and pretending otherwise
  /// would hide a selection bug behind a plausible number.
  ///
  /// - Parameters:
  ///   - id: Which product's selection to read.
  ///   - product: The product whose variant count bounds it.
  /// - Returns: A valid index into `product.variants`, or zero when it has none.
  private func clampedVariantIndex(for id: ProductID, in product: Product) -> Int {
    let selected = selectedVariant(id).wrappedValue
    return min(max(0, selected), max(0, product.variants.count - 1))
  }

  nonisolated deinit {}
}
