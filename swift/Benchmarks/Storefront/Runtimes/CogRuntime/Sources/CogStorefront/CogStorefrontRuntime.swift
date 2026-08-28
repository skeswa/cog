public import Cog
public import CogTesting
public import StorefrontWorkload

/// The Cog implementation of the Storefront workload, and the reference every
/// other port is measured against.
///
/// This adapter is thin on purpose. It owns the app-wide ``Cogs`` and the test
/// clock the runtime's lifetime work sleeps on, and every verb forwards to the
/// `CogOps` verb of the same name declared in `StorefrontState.swift`. Nothing
/// here decides anything: the multi-source turns, the staged reads, the
/// equality gates, and the demand-driven invalidation all live in the graph
/// declarations, which is exactly the point, this file is the seam that lets
/// the neutral trace drive them, not a second implementation of them.
///
/// It is also the definition of "no port may do less". Anything this adapter
/// does that a comparison port cannot is a finding about that port, not a
/// licence to soften the trace.
///
/// ## Identity and ownership
///
/// One instance per session, created by
/// ``make(profile:service:initialWindow:holds:sink:grace:)`` and retained by the
/// driver. It owns the context and the clock; the driver owns the script, the
/// sink, and the shadow world. Nothing recreates it mid-session, and the
/// context is never handed out except through ``cogs`` for the SwiftUI
/// application's environment installation.
///
/// ## Isolation
///
/// MainActor-confined, like ``Cogs`` itself. Every verb is a MainActor turn and
/// every asynchronous publish decision reaches the MainActor before it is made.
///
/// ## Turn and settlement ordering
///
/// Each verb is exactly one Cog turn, so when it returns the graph has settled:
/// every automatic value that a held reaction demands is current and every
/// reaction whose reads changed has already deposited into the sink. That
/// synchronous settlement is what lets the trace read the sink on the line
/// after a verb.
///
/// ## Cancellation and races
///
/// Both settlement barriers are Cog's own acknowledgements rather than
/// durations: ``settlingOneAsyncResult(_:)`` fires after the graph decides
/// about one result, accepted *or* refused, and
/// ``settlingLifetimeRelease(advancingBy:)`` fires after a grace-expiry
/// eligibility decision, including a negative one. Neither polls and neither
/// sleeps.
///
/// `nonisolated deinit` per the repository convention: a synthesized deinit
/// here would ask the concurrency runtime which executor it is on for every
/// deallocation.
@MainActor
public final class CogStorefrontRuntime: StorefrontRuntime {
  /// The per-generation demand handle this runtime hands back.
  public typealias Refresh = CogStorefrontRefresh

  /// The app-wide graph under measurement.
  ///
  /// `public` because the SwiftUI comparison application installs it with
  /// `.cogEnvironment(cogs)`; the headless trace never touches it and reaches
  /// the graph only through this adapter's verbs.
  public let cogs: Cogs

  /// The clock the context's lifetime grace sleeps on.
  ///
  /// Owned here rather than by the driver: a clock is one runtime's private
  /// business, and the neutral trace advances time only through
  /// ``settlingLifetimeRelease(advancingBy:)``.
  public let clock: TestClock

  /// What Cog is called in a benchmark name, and what it guarantees.
  ///
  /// The eleven-phase trace proves every value against Cog. One turn settles
  /// once. Equal writes and offscreen changes run nothing. The account reaction
  /// runs at registration and response. Grace releases unobserved values.
  /// Generations reject stale results, and `refresh` returns an exact-generation
  /// handle.
  public static let descriptor = StorefrontRuntimeDescriptor(
    slug: "cog",
    displayName: "Cog",
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

  /// Creates a runtime around an existing context and clock.
  ///
  /// Private because a Storefront session's context must be the one
  /// ``make(profile:service:initialWindow:holds:sink:grace:)`` assembled: the
  /// service installation and the starting row window happen inside the
  /// mechanism's `operate`, so a context assembled any other way would let a
  /// held reaction observe the pre-initial world on its way past.
  ///
  /// - Parameters:
  ///   - cogs: The assembled context.
  ///   - clock: The clock that context's grace sleeps on.
  private init(cogs: Cogs, clock: TestClock) {
    self.cogs = cogs
    self.clock = clock
  }

  // MARK: - Construction

  /// Assembles a fresh isolated graph whose initial state has already settled.
  ///
  /// ``StorefrontMechanism`` installs the service, writes the starting row
  /// window, and registers the held reactions inside assembly, so every one of
  /// those writes settles before `make` returns and the bootstrap phase's
  /// browse-run count is a claim about registration rather than about a race.
  ///
  /// - Parameters:
  ///   - profile: The world's size.
  ///   - service: The request boundary to install.
  ///   - initialWindow: The row window the list starts at.
  ///   - holds: Which durable reaction leases to register.
  ///   - sink: Where those reactions deposit what they read.
  ///   - grace: The context-wide `whileObserved` grace, measured on ``clock``.
  /// - Returns: A live runtime whose initial state has settled.
  public static func make(
    profile: StorefrontProfile,
    service: StorefrontService,
    initialWindow: RowWindow,
    holds: StorefrontHolds,
    sink: StorefrontSink,
    grace: Duration
  ) -> CogStorefrontRuntime {
    let clock = TestClock()
    let cogs = Cogs.forTesting(
      clock: clock,
      whileObservedGrace: grace,
      mechanisms: [
        StorefrontMechanism(
          service: service,
          initialWindow: initialWindow,
          holds: holds,
          sink: sink
        )
      ]
    )
    return CogStorefrontRuntime(cogs: cogs, clock: clock)
  }

  // MARK: - Domain operations

  // Every verb below is `@inlinable`, and that attribute is load-bearing rather
  // than decorative.
  //
  // The adapter exists to satisfy a protocol, not to be a layer: each verb is
  // one call forwarded to the `CogOps` verb of the same name. A benchmark that
  // billed the graph for that forwarding frame would be measuring the apparatus
  // that makes four runtimes comparable. `perf-15-storefront-interactions`
  // performs four verbs per iteration from the benchmark module, on the
  // concrete adapter, inside the measured region, so four forwarding frames is
  // four extra calls per sample, and it was measured at roughly 3% of that
  // cut's wall clock.
  //
  // `@inlinable` is what removes them, and `@inline(__always)` on its own is
  // not: that attribute is only an inliner directive within a module that can
  // already see the body, and an ordinary `public` body is never serialized
  // into `CogStorefront.swiftmodule`, so a cross-module caller has nothing to
  // inline. `@inlinable` serializes the body; `@inline(__always)` beside it
  // keeps the result from depending on an inliner heuristic. Both are needed,
  // and the pairing is deliberate.
  //
  // The alternative, cross-module optimization for this target, was rejected.
  // It is a whole-target build flag that changes codegen for everything in the
  // target, it would have to be repeated in every consumer that wants the same
  // shape, and the comparison's legibility rests on all four runtimes sharing
  // one `storefrontSwiftSettings`. A per-declaration attribute travels with the
  // module instead, so the benchmark, the SwiftUI application, and the tests
  // all get the identical adapter.

  /// Records the account response the graph accepted, or signs out.
  ///
  /// - Parameter shopper: The signed-in shopper, or `nil`.
  @inlinable
  @inline(__always)
  public func signIn(as shopper: Shopper?) {
    cogs.signIn(as: shopper)
  }

  /// Records the rows the list has materialized.
  ///
  /// - Parameter window: The new window.
  @inlinable
  @inline(__always)
  public func scrollRows(to window: RowWindow) {
    cogs.scrollRows(to: window)
  }

  /// Replaces the search field's contents.
  ///
  /// - Parameter text: The field's new contents.
  @inlinable
  @inline(__always)
  public func typeSearchQuery(_ text: String) {
    cogs.typeSearchQuery(text)
  }

  /// Applies the browse screen's filters and window in one turn.
  ///
  /// - Parameters:
  ///   - category: The category to filter to, or `nil` for all.
  ///   - sortMode: How to order results.
  ///   - inStockOnly: Whether to hide out-of-stock products.
  @inlinable
  @inline(__always)
  public func applyBrowseFilters(category: CategoryID?, sortMode: SortMode, inStockOnly: Bool) {
    cogs.applyBrowseFilters(category: category, sortMode: sortMode, inStockOnly: inStockOnly)
  }

  /// Selects one category without disturbing the rest of the filter bar.
  ///
  /// - Parameter category: The category, or `nil` for all.
  @inlinable
  @inline(__always)
  public func selectCategory(_ category: CategoryID?) {
    cogs.selectCategory(category)
  }

  /// Chooses how results are ordered.
  ///
  /// - Parameter mode: The sort mode.
  @inlinable
  @inline(__always)
  public func selectSortMode(_ mode: SortMode) {
    cogs.selectSortMode(mode)
  }

  /// Shows or hides out-of-stock products.
  ///
  /// - Parameter isOn: Whether to hide them.
  @inlinable
  @inline(__always)
  public func setInStockOnly(_ isOn: Bool) {
    cogs.setInStockOnly(isOn)
  }

  /// Toggles one product's favorite flag.
  ///
  /// - Parameter id: Which product.
  @inlinable
  @inline(__always)
  public func toggleFavorite(_ id: ProductID) {
    cogs.toggleFavorite(id)
  }

  /// Opens a product's detail screen and records that it was viewed.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - rank: The recency rank to record; larger is more recent.
  @inlinable
  @inline(__always)
  public func openProduct(_ id: ProductID, rank: Int) {
    cogs.openProduct(id, rank: rank)
  }

  /// Returns to the browse screen.
  @inlinable
  @inline(__always)
  public func closeProduct() {
    cogs.closeProduct()
  }

  /// Selects a variant of one product.
  ///
  /// - Parameters:
  ///   - variantIndex: Which variant.
  ///   - id: Which product.
  @inlinable
  @inline(__always)
  public func selectVariant(_ variantIndex: Int, for id: ProductID) {
    cogs.selectVariant(variantIndex, for: id)
  }

  /// Adds a product to the cart, or increases its quantity.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - quantity: How many to add.
  @inlinable
  @inline(__always)
  public func addToCart(_ id: ProductID, quantity: Int) {
    cogs.addToCart(id, quantity: quantity)
  }

  /// Sets one line's quantity, removing the line at zero.
  ///
  /// - Parameters:
  ///   - quantity: The new quantity; zero or less removes the line.
  ///   - id: Which product.
  @inlinable
  @inline(__always)
  public func setCartQuantity(_ quantity: Int, for id: ProductID) {
    cogs.setCartQuantity(quantity, for: id)
  }

  /// Applies or clears a coupon.
  ///
  /// - Parameter coupon: The typed coupon, or `nil` to clear it.
  @inlinable
  @inline(__always)
  public func applyCoupon(_ coupon: CouponCode?) {
    cogs.applyCoupon(coupon)
  }

  /// Chooses where the order ships.
  ///
  /// - Parameter address: The address.
  @inlinable
  @inline(__always)
  public func selectShippingAddress(_ address: ShippingAddress) {
    cogs.selectShippingAddress(address)
  }

  /// Chooses how the order ships.
  ///
  /// - Parameter method: The method.
  @inlinable
  @inline(__always)
  public func selectShippingMethod(_ method: ShippingMethod) {
    cogs.selectShippingMethod(method)
  }

  /// Publishes one inventory burst in one turn.
  ///
  /// - Parameters:
  ///   - ids: The products the feed touched.
  ///   - generation: The generation to advance them to.
  @inlinable
  @inline(__always)
  public func publishInventoryBurst(_ ids: [ProductID], generation: Int) {
    cogs.publishInventoryBurst(ids, generation: generation)
  }

  // MARK: - Asynchronous demand

  /// Demands a fresh catalog.
  @inlinable
  @inline(__always)
  public func refreshCatalog() {
    cogs.refreshCatalog()
  }

  /// Demands a fresh inventory reading for one product.
  ///
  /// - Parameter id: Which product.
  @inlinable
  @inline(__always)
  public func refreshInventory(for id: ProductID) {
    cogs.refreshInventory(for: id)
  }

  /// Demands fresh recommendations and hands back that demand's handle.
  ///
  /// - Returns: A handle bound to this generation, never to a later one.
  @inlinable
  @inline(__always)
  @discardableResult
  public func refreshRecommendations() -> CogStorefrontRefresh {
    CogStorefrontRefresh(refresh: cogs.refreshRecommendations())
  }

  // MARK: - Settled inspection

  /// The price the graph currently reports for one product.
  ///
  /// A `peek`, so it adds no dependency edge, extends no lifetime, and renews
  /// no grace deadline, the teardown phase's release proof depends on all
  /// three.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  @inlinable
  @inline(__always)
  public func peekEffectivePrice(of id: ProductID) -> Int {
    cogs.peek(storefrontEffectivePriceCogs[id])
  }

  /// The promotion plan the graph currently reports.
  ///
  /// - Returns: The settled promotion plan.
  @inlinable
  @inline(__always)
  public func peekPromotionPlan() -> PromotionPlan {
    cogs.peek(storefrontPromotionPlanCog)
  }

  /// Establishes a durable demand for the ranked product list and returns it.
  ///
  /// A tracked read rather than a `peek`, deliberately: the footprint cut
  /// weighs the search funnel this pulls in, so the read has to leave it
  /// materialized.
  ///
  /// - Returns: The ranked product identifiers, in rank order.
  @inlinable
  @inline(__always)
  @discardableResult
  public func demandRankedProductIDs() -> [ProductID] {
    cogs[storefrontRankedProductIDsCog]
  }

  // MARK: - Settlement barriers

  /// Runs `body` and returns once the graph has decided about one async result.
  ///
  /// The acknowledgement is installed *before* `body` runs, because a scripted
  /// release can resume and publish before the caller would otherwise be
  /// suspended. It fires for accepted completions **and** for stale, cancelled,
  /// released, and invalidated ones Cog drops, which is what makes it a
  /// definite signal for the search phase's stale step.
  ///
  /// - Parameter body: The release that produces the result.
  @inlinable
  @inline(__always)
  public func settlingOneAsyncResult(_ body: () async throws -> Void) async throws {
    let acknowledged = MainActorCleanupAcknowledgement()
    cogs.acknowledgeNextAsyncCompletionCheck(with: acknowledged)
    try await body()
    try await acknowledged.wait()
  }

  /// Advances the injected clock past grace and returns once Cog has decided
  /// what to release.
  ///
  /// The eligibility acknowledgement fires on a negative decision too, so a
  /// phase can establish that the graph made up its mind about a value an
  /// observer correctly pinned without polling for a removal that will never
  /// come.
  ///
  /// - Parameter duration: How far past grace to advance.
  @inlinable
  @inline(__always)
  public func settlingLifetimeRelease(advancingBy duration: Duration) async throws {
    let released = MainActorCleanupAcknowledgement()
    cogs.acknowledgeNextAutomaticReleaseCheck(with: released)
    clock.advance(by: duration)
    try await released.wait()
  }

  nonisolated deinit {}
}

/// Cog's per-generation recommendation demand handle, in neutral vocabulary.
///
/// A thin wrapper rather than a conformance on `CogRefresh` itself, because
/// `CogRefresh` is Cog's API and the neutral protocol is the workload's: mapping
/// the four outcome cases here keeps the translation in one visible place and
/// keeps `StorefrontWorkload` free of any Cog symbol.
///
/// `Sendable` because ``StorefrontRefreshHandle`` is: the handle may be awaited
/// from a task other than the one that created it, and Cog resolves the
/// underlying completion cell on the MainActor.
public struct CogStorefrontRefresh: StorefrontRefreshHandle {
  /// What this generation produced.
  public typealias Value = [ProductID]

  /// The Cog handle bound to exactly one generation.
  private let refresh: CogRefresh<[ProductID]>

  /// Wraps one Cog refresh handle.
  ///
  /// - Parameter refresh: The handle `Cogs.refresh(_:)` returned. It belongs to
  ///   the generation that call started and never drifts to a later one.
  ///
  /// `@usableFromInline` rather than `public`: the wrapper is not something a
  /// caller may build, but ``CogStorefrontRuntime/refreshRecommendations()`` is
  /// `@inlinable` and its body names this initializer, so the initializer's
  /// signature has to be visible to whatever module inlines it. The body stays
  /// here and stays out of line; only the name crosses.
  @usableFromInline
  init(refresh: CogRefresh<[ProductID]>) {
    self.refresh = refresh
  }

  /// The terminal result of this exact generation.
  ///
  /// Resolves without a clock and without a poll: replacement resolves it as
  /// ``StorefrontRefreshOutcome/superseded`` at the moment of replacement, and
  /// lifetime release resolves it as ``StorefrontRefreshOutcome/released``.
  /// Cog retains the resolved outcome, so awaiting after the graph has moved on
  /// still answers about the generation this handle names.
  public var outcome: StorefrontRefreshOutcome<[ProductID]> {
    get async {
      switch await refresh.outcome {
      case .success(let value): .success(value)
      case .failure(let error): .failure(error)
      case .superseded: .superseded
      case .released: .released
      }
    }
  }
}
