internal import Observation
internal import StorefrontWorkload

/// Every writable fact the hand-memoized Storefront port owns, on one
/// `@Observable` object.
///
/// This is the full source layer. Its seventeen facts match Cog's manual
/// declarations: eleven keyless properties, five keyed dictionaries, and the
/// installed ``StorefrontService``.
///
/// ## Why dictionaries rather than an object per product
///
/// A per-product `@Observable` object would improve invalidation but allocate
/// 1,200 mostly unused objects. Dictionaries are the practical choice. A write
/// to one favorite notifies all `favorites` readers, so hand-written caches
/// restore per-product granularity. This benchmark measures that cost.
///
/// ## Identity, ownership, and isolation
///
/// One instance per runtime, created in
/// ``MemoObservationStorefrontRuntime/make(profile:service:initialWindow:holds:sink:grace:)``
/// and never shared or replaced. Every verb and render accesses it on the
/// MainActor.
///
/// ## Observation
///
/// SwiftUI reads these properties from view bodies. The headless port uses
/// `withObservationTracking` so samples include registrar cost. Observation is
/// not the invalidation system: methods in `MemoObservationInvalidation.swift`
/// invalidate each cache by hand.
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
  /// cache at all, see
  /// ``MemoObservationStorefrontRuntime/publishInventoryBurst(_:generation:)``.
  var inventoryGenerations: [ProductID: Int] = [:]

  /// Creates a model resting at the values a fresh session starts from.
  init() {}

  nonisolated deinit {}
}
