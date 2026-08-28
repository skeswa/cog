/// One state-management runtime's implementation of the Storefront workload.
///
/// The eleven-phase trace uses this protocol so all four ports run the same
/// session. A phase calls these verbs or reads ``StorefrontSink``,
/// ``StorefrontScript``, and ``StorefrontWorld``. It never reads private runtime
/// state, keeping results comparable.
///
/// ## Identity and ownership
///
/// A runtime is one app-wide object, created by
/// ``make(profile:service:initialWindow:holds:sink:grace:)`` and retained by the
/// driver for the life of a session. It is never copied, never handed to a
/// phase by value, or recreated. It owns storage, async work, and a clock. The
/// driver owns the script, sink, and shadow.
///
/// ## Isolation
///
/// MainActor-confined: verbs write there, derived reads settle there, and async
/// results publish there. Heavy kernels may run elsewhere, but every publish
/// decision returns to the MainActor.
///
/// ## Turn and settlement ordering
///
/// Each verb is exactly one user action and therefore exactly one settlement.
/// Multi-source verbs write all sources in one transaction. Reads inside that
/// transaction see staged values. On return, derived values are current and
/// affected held observers have written to the sink. The trace reads the sink
/// on the next line, so lazy settlement cannot satisfy it.
///
/// ## Observation
///
/// The `holds` set names the screens a shopper would have open. A runtime must
/// register only those observers. Unheld screens create no demand or requests.
/// Each observer writes to ``StorefrontSink`` and increments its run count.
/// ``StorefrontRuntimeSemantics`` declares when each port should run.
///
/// ## Cancellation and races
///
/// The trace never waits on a duration and never polls. Every suspension is a
/// definite signal the runtime itself gives:
/// ``settlingOneAsyncResult(_:)`` and ``settlingLifetimeRelease(advancingBy:)``.
/// Acceptance of an asynchronous result must be keyed on the request identity
/// and generation captured *synchronously at selection time*, never on task
/// cancellation: ``StorefrontScript`` leaves cancelled requests suspended by
/// default precisely so a port cannot pass the stale-result checkpoint by
/// accident.
@MainActor
public protocol StorefrontRuntime: AnyObject {
  /// The handle one demand for fresh asynchronous work hands back.
  associatedtype Refresh: StorefrontRefreshHandle where Refresh.Value == [ProductID]

  /// What this runtime is called in a benchmark name and a results table, and
  /// what it structurally guarantees.
  ///
  /// `static` because it describes the implementation strategy rather than one
  /// session's configuration. A port that declared the wrong semantics to make
  /// a run-count checkpoint pass would fail the identity and checksum
  /// checkpoints instead, which no runtime is exempt from.
  static var descriptor: StorefrontRuntimeDescriptor { get }

  // MARK: - Construction

  /// Builds a fresh, isolated runtime whose initial state has already settled.
  ///
  /// The service installation and the starting row window happen *inside* this
  /// call, before anything observes, so no phase and no held observer ever sees
  /// the pre-initial world on its way past. In Cog that is a mechanism's
  /// `operate`; in another runtime it is whatever runs before the first read.
  /// Registering the observers named by `holds` is also this call's job, and
  /// each of them runs once here, the bootstrap phase's browse-run count is a
  /// claim about exactly that.
  ///
  /// - Parameters:
  ///   - profile: The world's size. Fixed for the session.
  ///   - service: The installed request boundary. Every asynchronous selection
  ///     must go through this exact instance and must call
  ///     ``StorefrontService/schedule(_:)`` synchronously, on the MainActor,
  ///     before launching any task.
  ///   - initialWindow: The row window the list starts at.
  ///   - holds: Which durable observers to register, one per screen a shopper
  ///     would have open.
  ///   - sink: Where those observers deposit what they read and count their
  ///     own runs. Shared with the driver; the runtime writes, never reads.
  ///   - grace: How long a value with no observer may survive before release.
  ///     A runtime with no lifetime model ignores it and declares
  ///     ``StorefrontRuntimeSemantics/releasesUnobservedValues`` `false`.
  /// - Returns: A live runtime whose initial state has settled.
  static func make(
    profile: StorefrontProfile,
    service: StorefrontService,
    initialWindow: RowWindow,
    holds: StorefrontHolds,
    sink: StorefrontSink,
    grace: Duration
  ) -> Self

  // MARK: - Domain operations

  /// Records the account response the runtime accepted, or signs out.
  ///
  /// Called by the runtime's own account observer, and by nothing else. It is a
  /// protocol requirement anyway because the SwiftUI comparison apps need a
  /// sign-out affordance.
  ///
  /// - Parameter shopper: The signed-in shopper, or `nil`.
  func signIn(as shopper: Shopper?)

  /// Records the rows the list has materialized.
  ///
  /// The demand boundary: rows outside this window widened by the profile's
  /// prefetch margin must not be computed and must not start requests.
  ///
  /// - Parameter window: The new window.
  func scrollRows(to window: RowWindow)

  /// Replaces the search field's contents.
  ///
  /// A whole-value write rather than an append, because the field's value is
  /// the fact. Two keystrokes that normalize identically must not start two
  /// suggestion generations; the search phase counts exactly that.
  ///
  /// - Parameter text: The field's new contents.
  func typeSearchQuery(_ text: String)

  /// Applies the browse screen's filters and resets the window, in one settle.
  ///
  /// **Multi-source, and it reads its own staged state.** Four sources change
  /// together, category, sort mode, stock filter, and the row window, and the
  /// window's new value is `RowWindow(offset: 0, length: <the transaction's own
  /// staged window length>)`. Three or four separate writes would render two or
  /// three screens no shopper asked for, and the filter phase's one-run
  /// checkpoint would catch it.
  ///
  /// - Parameters:
  ///   - category: The category to filter to, or `nil` for all.
  ///   - sortMode: How to order results.
  ///   - inStockOnly: Whether to hide out-of-stock products.
  func applyBrowseFilters(category: CategoryID?, sortMode: SortMode, inStockOnly: Bool)

  /// Selects one category without disturbing the rest of the filter bar.
  ///
  /// - Parameter category: The category, or `nil` for all.
  func selectCategory(_ category: CategoryID?)

  /// Chooses how results are ordered.
  ///
  /// Writing the mode that is already selected must settle and, for a runtime
  /// that declares an equality gate, render nothing. The filter phase writes
  /// the same mode twice on purpose.
  ///
  /// - Parameter mode: The sort mode.
  func selectSortMode(_ mode: SortMode)

  /// Shows or hides out-of-stock products.
  ///
  /// - Parameter isOn: Whether to hide them.
  func setInStockOnly(_ isOn: Bool)

  /// Toggles one product's favorite flag.
  ///
  /// **Reads its own staged value.** The new flag is the negation of the
  /// current one, read inside the transaction, so two toggles in one settle
  /// would cancel rather than both setting `true`.
  ///
  /// - Parameter id: Which product.
  func toggleFavorite(_ id: ProductID)

  /// Opens a product's detail screen and records that it was viewed.
  ///
  /// **Multi-source.** Selection and recency rank change together. A split
  /// would render the detail screen against a stale rank and would run the
  /// recency-dependent pricing stage twice for one navigation.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - rank: The recency rank to record; larger is more recent. Session
  ///     bookkeeping, so the caller supplies it rather than the runtime
  ///     inventing a counter each port would get subtly different.
  func openProduct(_ id: ProductID, rank: Int)

  /// Returns to the browse screen.
  ///
  /// After this settles the detail observer must read nothing but the (now
  /// `nil`) selection, which is what lets the detail payload and the
  /// recommendation shelf become releasable.
  func closeProduct()

  /// Selects a variant of one product.
  ///
  /// - Parameters:
  ///   - variantIndex: Which variant. Ports clamp exactly where
  ///     ``StorefrontPricing`` clamps and nowhere else; the availability
  ///     computation is deliberately unclamped.
  ///   - id: Which product.
  func selectVariant(_ variantIndex: Int, for id: ProductID)

  /// Adds a product to the cart, or increases its quantity.
  ///
  /// **Multi-source, conditional on a staged read.** The quantity becomes the
  /// staged quantity plus `quantity`, and the membership list gains `id` only
  /// when the staged quantity was zero. Writing the two separately would let a
  /// settled state observe a product that is in the cart with quantity zero,
  /// and would start a shipping and tax quote generation for that impossible
  /// subtotal, which the checkout phase's quote-replacement checkpoint counts.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - quantity: How many to add.
  func addToCart(_ id: ProductID, quantity: Int)

  /// Sets one line's quantity, removing the line at zero.
  ///
  /// **Multi-source, conditional on a staged read.** Same contract as
  /// ``addToCart(_:quantity:)``: quantity is clamped at zero, membership is
  /// filtered out at zero or appended when absent, both in one transaction.
  ///
  /// - Parameters:
  ///   - quantity: The new quantity; zero or less removes the line.
  ///   - id: Which product.
  func setCartQuantity(_ quantity: Int, for id: ProductID)

  /// Applies or clears a coupon.
  ///
  /// - Parameter coupon: The typed coupon, or `nil` to clear it.
  func applyCoupon(_ coupon: CouponCode?)

  /// Chooses where the order ships.
  ///
  /// - Parameter address: The address.
  func selectShippingAddress(_ address: ShippingAddress)

  /// Chooses how the order ships.
  ///
  /// - Parameter method: The method.
  func selectShippingMethod(_ method: ShippingMethod)

  /// Publishes one inventory burst.
  ///
  /// **Multi-source over N keys, one transaction.** Every touched product's
  /// generation advances together, which is what a warehouse feed looks like
  /// and what makes the burst phase's central claim measurable: one settle, and
  /// only the demanded rows among the touched products recompute or request
  /// anything. Per-product writes would produce N settles and break the phase
  /// outright.
  ///
  /// - Parameters:
  ///   - ids: The products the feed touched.
  ///   - generation: The generation to advance them to.
  func publishInventoryBurst(_ ids: [ProductID], generation: Int)

  // MARK: - Asynchronous demand

  /// Re-demands the catalog.
  ///
  /// Not used by the trace; the SwiftUI comparison apps expose it as
  /// pull-to-refresh.
  func refreshCatalog()

  /// Re-demands one product's inventory.
  ///
  /// - Parameter id: Which product.
  func refreshInventory(for id: ProductID)

  /// Demands fresh recommendations and hands back *that exact demand's* handle.
  ///
  /// The handle is returned rather than discarded because a replaced demand is
  /// a definite signal: it resolves without a clock, a poll, or a timeout, and
  /// the teardown phase's replacement checkpoint is built on exactly that. A
  /// runtime with no per-generation demand handle declares
  /// ``StorefrontRuntimeSemantics/hasPerGenerationRefreshHandles`` `false` and
  /// the trace skips that one checkpoint rather than greening it vacuously.
  ///
  /// - Returns: A handle bound to this generation, never to a later one.
  @discardableResult
  func refreshRecommendations() -> Refresh

  // MARK: - Settled inspection

  /// The price this runtime currently reports for one product.
  ///
  /// An *untracked* settled read: a checkpoint reading a value, not a screen
  /// observing one. It must not create a dependency, extend a lifetime, or
  /// renew a grace deadline, the teardown phase's release proof would be
  /// invalidated by either, and a port whose only read primitive establishes
  /// demand must arrange an untracked path rather than let this one leak.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The effective price in cents.
  func peekEffectivePrice(of id: ProductID) -> Int

  /// The promotion plan this runtime currently reports.
  ///
  /// Untracked, for the same reason as ``peekEffectivePrice(of:)``.
  ///
  /// - Returns: The settled promotion plan.
  func peekPromotionPlan() -> PromotionPlan

  /// Establishes a durable demand for the ranked product list and returns it.
  ///
  /// The opposite of the two peeks above, and the footprint cut's whole
  /// subject: this read *does* create demand, so the search funnel it pulls in
  ///, index, candidates, eligibility, scores, ranking, stays materialized
  /// afterwards and can be weighed.
  ///
  /// - Returns: The ranked product identifiers, in rank order.
  @discardableResult
  func demandRankedProductIDs() -> [ProductID]

  // MARK: - Settlement barriers

  /// Runs `body` and returns once exactly one asynchronous result has reached
  /// this runtime's publish decision.
  ///
  /// The barrier is armed *before* `body` runs, because a scripted release can
  /// resume and publish before the caller would otherwise be suspended. It must
  /// fire for an accepted result **and** for a stale, cancelled, released, or
  /// invalidated one the runtime drops, which is precisely what the search
  /// phase's stale step needs: that step's whole subject is a result the
  /// runtime deliberately refuses.
  ///
  /// The request script cannot supply this signal on a port's behalf. A
  /// released continuation resumes, and the script's outstanding count drops,
  /// *before* the runtime has decided anything, so a port that awaited the
  /// script would return too early and race its own publication. The signal
  /// must be fired by the runtime, on the MainActor, on both the publish and
  /// the discard branch of its own result epilogue. See
  /// ``StorefrontCompletionSignal`` for the one-shot primitive to fire.
  ///
  /// Awaiting a duration, yielding in a loop, or sleeping is prohibited. A port
  /// that does any of those turns the stale-result checkpoint into a coin flip.
  ///
  /// - Parameter body: The release that will produce the result. Runs after the
  ///   barrier is armed.
  func settlingOneAsyncResult(_ body: () async throws -> Void) async throws

  /// Advances this runtime's injected clock past its grace period and returns
  /// once the runtime has finished deciding what to release.
  ///
  /// The signal must fire on a *negative* decision too: a value correctly
  /// pinned by an observer surviving grace is still a completed decision, and a
  /// phase must be able to establish that the runtime made up its mind without
  /// polling. A runtime that declares
  /// ``StorefrontRuntimeSemantics/releasesUnobservedValues`` `false` returns
  /// immediately, and the trace skips the phase's release proof.
  ///
  /// - Parameter duration: How far past grace to advance.
  func settlingLifetimeRelease(advancingBy duration: Duration) async throws
}
