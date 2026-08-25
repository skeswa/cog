import Observation
import StorefrontWorkload

/// Every writable fact in the Storefront workload, as plain `@Observable`
/// stored properties.
///
/// This is the whole state layer of the raw port. The seventeen sources the Cog
/// graph declares — twelve keyless and five keyed — land here as twelve stored
/// properties and five dictionaries, and the ten asynchronous values land as ten
/// more stored properties holding the last accepted response. There is nothing
/// else: no derived storage, no dirty bits, no edge list, and no per-node
/// wrapper. Every derived value in this port is recomputed from these
/// properties on every read, which is precisely the floor the comparison is
/// measuring.
///
/// ## Why the keyed sources are dictionaries on one object
///
/// A favorite flag, a cart quantity, a selected variant, a recency rank, and an
/// inventory generation are all facts about one product, and Cog gives each
/// product its own cell. Here they are five dictionaries on a single
/// `@Observable` object, because that is what a team writes when Observation is
/// the only tool available: one model object per screen's worth of state, keyed
/// collections inside it. The consequence is coarse invalidation — writing one
/// product's favorite flag notifies every reader of the whole `favorites`
/// dictionary — and that coarseness is part of what is being measured rather
/// than a defect to be engineered around.
///
/// ## Identity and ownership
///
/// One instance per session, created and retained by
/// ``RawObservationStorefrontRuntime``. Nothing outside that runtime ever holds
/// a reference, and the runtime never replaces it: the model's identity is the
/// session's identity.
///
/// ## Isolation
///
/// MainActor-confined, because every write is a user action and every read
/// happens inside the runtime's synchronous render. Asynchronous responses are
/// published here only after their task has returned to the MainActor.
///
/// ## Observation
///
/// The properties are macro-instrumented, so a read taken inside
/// `withObservationTracking` registers with the standard-library registrar and a
/// later write notifies it. The runtime deliberately keeps that registration in
/// the measured path — see ``RawObservationStorefrontRuntime`` — while driving
/// its own rendering explicitly, because Observation's change callback is not a
/// settlement barrier.
///
/// `nonisolated deinit` per the repository convention: under
/// `.defaultIsolation(MainActor.self)` a synthesized deinit would ask the
/// concurrency runtime which executor it is on for every deallocation.
@MainActor
@Observable
final class RawObservationStorefrontModel {
  // MARK: - Keyless sources

  /// The injected request boundary, and the profile it serves.
  ///
  /// A stored property rather than a global so a test, a benchmark cut, and an
  /// application can each install a different script without any of them
  /// reaching into another's world. It is written once, inside
  /// ``RawObservationStorefrontRuntime/make(profile:service:initialWindow:holds:sink:grace:)``,
  /// before anything observes.
  var service: StorefrontService

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
  /// Deliberately a source of its own rather than a read of ``account``:
  /// signing out is a local action that must not wait on a request, and the
  /// runtime's account observer writes the accepted response here. One writable
  /// fact, one writable place — the same split the Cog port makes.
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
  var cartContents: [ProductID] = []

  // MARK: - Keyed sources

  /// Whether each product is favorited; a missing key means `false`.
  var favorites: [ProductID: Bool] = [:]

  /// How many of each product are in the cart; a missing key means zero.
  var cartQuantities: [ProductID: Int] = [:]

  /// Which variant of each product is selected; a missing key means zero.
  var selectedVariants: [ProductID: Int] = [:]

  /// How recently each product was viewed; a missing key, or zero, means never.
  var recentlyViewedRanks: [ProductID: Int] = [:]

  /// Which inventory generation each product is asking the service for.
  var inventoryGenerations: [ProductID: Int] = [:]

  // MARK: - Accepted asynchronous responses

  // Each property below rests on the same declaration default its Cog
  // counterpart rests on, and holds the last accepted success afterwards.
  // Reads of them are total: a request in flight does not make the value
  // unavailable, and no loading case ever reaches a screen. Surfacing one would
  // change what the browse observer depends on, and therefore its run counts.

  /// The accepted catalog.
  var catalog: CatalogSnapshot = .empty

  /// The accepted account response, or `nil` before one lands.
  var account: Shopper?

  /// The accepted inverted search index.
  var searchIndex: StorefrontKernels.SearchIndex = .empty

  /// The accepted suggestions for the current query.
  var suggestions: [String] = []

  /// The accepted recommendations.
  var recommendations: [ProductID] = []

  /// Accepted live inventory, by product; a missing key means
  /// ``InventoryReading/unknown``.
  var inventory: [ProductID: InventoryReading] = [:]

  /// Accepted personalized offers, by product; a missing key means
  /// ``PersonalizedOffer/none``.
  var offers: [ProductID: PersonalizedOffer] = [:]

  /// Accepted detail payloads, by product; a missing key means
  /// ``ProductDetail/empty``.
  var details: [ProductID: ProductDetail] = [:]

  /// The accepted shipping quote.
  var shippingQuote: ShippingQuote = .pending

  /// The accepted tax quote.
  var taxQuote: TaxQuote = .pending

  /// Creates a model resting at every declaration default.
  ///
  /// - Parameter service: The request boundary this session talks to.
  init(service: StorefrontService) {
    self.service = service
  }

  nonisolated deinit {}
}
