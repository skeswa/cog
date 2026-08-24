internal import Observation
internal import StorefrontWorkload

/// Every writable fact the hand-memoized Storefront port owns, on one
/// `@Observable` object.
///
/// This is the port's whole *source* layer: seventeen mutable facts, mapped one
/// for one onto the Cog port's seventeen manual declarations — eleven keyless
/// stored properties here, five `[ProductID: T]` dictionaries here, and the
/// installed ``StorefrontService``, which the runtime holds directly because it
/// is injected once at construction and never written again.
///
/// ## Why dictionaries rather than an object per product
///
/// Because that is what a team writes. A per-product `@Observable` object would
/// buy finer Observation-level invalidation, at the cost of allocating and
/// wiring twelve hundred objects for a catalog whose rows are mostly never
/// visited. The coarser thing is both the realistic choice and part of what the
/// comparison is measuring: a write to any product's favorite flag notifies
/// every reader of `favorites`. The port's *own* caches are what recover the
/// per-product granularity, by hand, and the cost of writing that by hand is
/// the number this runtime exists to produce.
///
/// ## Identity, ownership, and isolation
///
/// One instance per runtime, created in
/// ``MemoObservationStorefrontRuntime/make(profile:service:initialWindow:holds:sink:grace:)``
/// and never replaced or shared. MainActor-confined, like every other type in
/// this port and like the `@Observable` models a SwiftUI application keeps:
/// every verb writes it on the MainActor and every render reads it there.
///
/// ## Observation
///
/// The `@Observable` macro is here for the same reason it would be in a real
/// application — a SwiftUI sibling app reads these properties from view bodies
/// — and the headless port reads them inside `withObservationTracking` so the
/// registrar's registration cost stays inside the measured sample rather than
/// being quietly optimized away by a benchmark that never observes anything.
/// Observation is **not** this port's invalidation mechanism. Nothing here
/// subscribes to a change callback; every cache this port keeps is invalidated
/// by a hand-written, explicitly enumerated `didWrite…`/`didAccept…` method in
/// `MemoObservationInvalidation.swift`.
///
/// `nonisolated deinit` per the repository convention: under
/// `.defaultIsolation(MainActor.self)` a synthesized deinit would ask the
/// concurrency runtime which executor it is on for every deallocation.
@Observable
final class MemoObservationStorefrontModel {
  /// The raw text in the search field, exactly as typed.
  var searchQuery = ""

  /// The category chip the shopper selected, or `nil` for all categories.
  var selectedCategory: CategoryID?

  /// How results are ordered.
  var sortMode: SortMode = .relevance

  /// Whether out-of-stock products are hidden.
  var inStockOnly = false

  /// The signed-in shopper, or `nil` before the account response is accepted.
  ///
  /// A written fact rather than a read of the account request's value, exactly
  /// as in the Cog port: signing out is a local action that must not wait on a
  /// request, and the account response's acceptance writes it here.
  var signedInShopper: Shopper?

  /// The coupon the shopper typed, or `nil`.
  var coupon: CouponCode?

  /// Where the order ships.
  var shippingAddress = StorefrontFixtures.startingAddress

  /// How the order ships.
  var shippingMethod: ShippingMethod = .standard

  /// The product whose detail screen is open, or `nil` on the browse screen.
  var selectedProduct: ProductID?

  /// The window of rows the list has materialized.
  var rowWindow = RowWindow(offset: 0, length: 0)

  /// The products in the cart, in the order they were added.
  ///
  /// Membership is a list and quantity is a dictionary, the same split the Cog
  /// port makes and for the same reason: a cart screen renders membership in
  /// order, while changing one line's quantity should not disturb the others.
  var cartContents: [ProductID] = []

  /// Whether each product is favorited.
  var favorites: [ProductID: Bool] = [:]

  /// How many of each product are in the cart.
  var cartQuantities: [ProductID: Int] = [:]

  /// Which variant of each product is selected.
  var selectedVariants: [ProductID: Int] = [:]

  /// How recently each product was viewed; zero means never.
  var recentlyViewedRanks: [ProductID: Int] = [:]

  /// Which inventory generation each product is asking the service for.
  ///
  /// A fetch key rather than a rendered value, which is the single most
  /// important thing to understand about this dictionary. Advancing a
  /// generation says "the reading you are holding is out of date"; it does not
  /// say what the new reading is. The row keeps rendering the last accepted
  /// reading until the new response lands, so a generation write invalidates no
  /// cache at all — see
  /// ``MemoObservationStorefrontRuntime/publishInventoryBurst(_:generation:)``.
  var inventoryGenerations: [ProductID: Int] = [:]

  /// Creates a model resting at the values a fresh session starts from.
  init() {}

  nonisolated deinit {}
}
