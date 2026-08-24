/// Where a held reaction deposits what it read.
///
/// Two jobs, both of which a benchmark needs and neither of which a screen
/// does. It carries settled values out of the graph so a measured region never
/// has to perform a read of its own, and it counts how many times each held
/// reaction actually ran — which is this workload's public, layout-agnostic way
/// of observing invalidation. A reaction runs again exactly when something it
/// read changed, so "the browse reaction did not run" is a provable claim about
/// an inventory burst that only touched offscreen products.
///
/// MainActor-confined because reactions are. `nonisolated deinit` because every
/// class in this repository declares one: under
/// `.defaultIsolation(MainActor.self)` a synthesized deinit asks the
/// concurrency runtime which executor it is on for every deallocation.
@MainActor
public final class StorefrontSink {
  /// How many times the browse reaction has run.
  public private(set) var browseRuns = 0

  /// How many times the search reaction has run.
  public private(set) var searchRuns = 0

  /// How many times the cart reaction has run.
  public private(set) var cartRuns = 0

  /// How many times the detail reaction has run.
  public private(set) var detailRuns = 0

  /// How many times the account reaction has run.
  public private(set) var accountRuns = 0

  /// The products the last browse run found on screen, in list order.
  public private(set) var visibleProductIDs: [ProductID] = []

  /// The products whose row state the last browse run demanded, in list order.
  ///
  /// This includes the visible window and its prefetch margin. The async-burst
  /// benchmark uses the recorded set after timing to prove it touched exactly
  /// the rows the measured reaction actually held, without reading the graph
  /// inside the measured region.
  public private(set) var demandedProductIDs: [ProductID] = []

  /// A digest of every visible row's rendered content, in order.
  ///
  /// Order-sensitive, so two screens showing the same products in a different
  /// order are different checksums.
  public private(set) var visibleChecksum = 0

  /// The suggestions the last search run saw.
  public private(set) var suggestions: [String] = []

  /// The cart's money as of the last cart run.
  public private(set) var orderTotal = OrderTotal(
    subtotalCents: 0,
    discountCents: 0,
    discountedSubtotalCents: 0,
    taxCents: 0,
    shippingCents: 0
  )

  /// Whether checkout was ready as of the last cart run.
  public private(set) var checkoutReadiness = CheckoutReadiness(isReady: false, blockers: [])

  /// The open product's review count, or zero when no product is open.
  public private(set) var detailReviewCount = 0

  /// The recommendations the last detail run saw.
  public private(set) var recommendations: [ProductID] = []

  /// Creates an empty sink.
  public init() {}

  /// Records one browse run and what it saw.
  ///
  /// - Parameters:
  ///   - visible: The visible products, in list order.
  ///   - demanded: The visible and prefetched products whose rows were read.
  ///   - checksum: The digest of their rendered content.
  public func recordBrowse(visible: [ProductID], demanded: [ProductID], checksum: Int) {
    browseRuns += 1
    visibleProductIDs = visible
    demandedProductIDs = demanded
    visibleChecksum = checksum
  }

  /// Records one search run and what it saw.
  ///
  /// - Parameter suggestions: The accepted suggestions.
  public func recordSearch(suggestions: [String]) {
    searchRuns += 1
    self.suggestions = suggestions
  }

  /// Records one cart run and what it saw.
  ///
  /// - Parameters:
  ///   - total: The cart's money.
  ///   - readiness: Whether checkout was ready.
  public func recordCart(total: OrderTotal, readiness: CheckoutReadiness) {
    cartRuns += 1
    orderTotal = total
    checkoutReadiness = readiness
  }

  /// Records one detail run and what it saw.
  ///
  /// - Parameters:
  ///   - reviewCount: The open product's review count, or zero.
  ///   - recommendations: The accepted recommendations.
  public func recordDetail(reviewCount: Int, recommendations: [ProductID]) {
    detailRuns += 1
    detailReviewCount = reviewCount
    self.recommendations = recommendations
  }

  /// Records one account run.
  public func recordAccount() {
    accountRuns += 1
  }

  nonisolated deinit {}
}
