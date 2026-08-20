public import Cog

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
  func recordBrowse(visible: [ProductID], demanded: [ProductID], checksum: Int) {
    browseRuns += 1
    visibleProductIDs = visible
    demandedProductIDs = demanded
    visibleChecksum = checksum
  }

  /// Records one search run and what it saw.
  ///
  /// - Parameter suggestions: The accepted suggestions.
  func recordSearch(suggestions: [String]) {
    searchRuns += 1
    self.suggestions = suggestions
  }

  /// Records one cart run and what it saw.
  ///
  /// - Parameters:
  ///   - total: The cart's money.
  ///   - readiness: Whether checkout was ready.
  func recordCart(total: OrderTotal, readiness: CheckoutReadiness) {
    cartRuns += 1
    orderTotal = total
    checkoutReadiness = readiness
  }

  /// Records one detail run and what it saw.
  ///
  /// - Parameters:
  ///   - reviewCount: The open product's review count, or zero.
  ///   - recommendations: The accepted recommendations.
  func recordDetail(reviewCount: Int, recommendations: [ProductID]) {
    detailRuns += 1
    detailReviewCount = reviewCount
    self.recommendations = recommendations
  }

  /// Records one account run.
  func recordAccount() {
    accountRuns += 1
  }

  nonisolated deinit {}
}

/// The Storefront's one mechanism: initial state, the account reaction, and the
/// durable leases a headless driver needs.
///
/// Initial app state lives here rather than in the app entry point, which is
/// both the repository's convention and the only placement that works:
/// `operate` runs inside bootstrap, so the installed service and the starting
/// row window settle before anything observes the graph, and no watcher sees
/// the pre-initial world on its way past.
///
/// The `holds` set is the one thing that differs between the application and
/// the headless driver. A SwiftUI app needs no leases — its views are the
/// observation. A benchmark has no views, so it registers reactions instead,
/// which is also what keeps a measured region quiescent: a reaction lease
/// neither drops the context nor renews a `whileObserved` grace sleeper the way
/// a bare `peek` inside the measured region would.
public struct StorefrontMechanism: Mechanism {
  /// Which durable leases this mechanism registers.
  ///
  /// Each corresponds to one screen a real shopper would have open, so a hold
  /// set is a statement about what the session is looking at rather than a
  /// benchmark knob.
  public struct Holds: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    /// Accept the account response into the signed-in-shopper source.
    ///
    /// Effectively always wanted: pricing, offers, and recommendations all read
    /// the shopper, and nothing else writes it.
    public static let account = Holds(rawValue: 1 << 0)

    /// Hold the visible rows, and demand the prefetch margin.
    public static let browse = Holds(rawValue: 1 << 1)

    /// Hold the search suggestions the search field displays.
    public static let search = Holds(rawValue: 1 << 2)

    /// Hold the cart's money and readiness.
    public static let cart = Holds(rawValue: 1 << 3)

    /// Hold the open product's detail payload and the recommendation shelf.
    public static let detail = Holds(rawValue: 1 << 4)

    /// Everything a headless driver wants.
    public static let all: Holds = [.account, .browse, .search, .cart, .detail]

    /// The browse-only subset the quiescent interaction cut uses.
    ///
    /// Deliberately excludes `.cart`'s downstream quotes and `.search`'s
    /// suggestion requests, because a measured region that starts async work is
    /// not a region process-global allocation counters may be attached to.
    public static let quiescentBrowse: Holds = [.account, .browse]
  }

  /// Attribution in debug history and task names.
  public let name: String

  /// The request boundary to install.
  public let service: StorefrontService

  /// The row window to start at.
  public let initialWindow: RowWindow

  /// Which leases to register.
  public let holds: Holds

  /// Where held reactions deposit what they read.
  public let sink: StorefrontSink

  /// Creates the mechanism.
  ///
  /// - Parameters:
  ///   - name: Attribution; defaults to `Storefront`.
  ///   - service: The request boundary to install.
  ///   - initialWindow: The row window to start at. The application overwrites
  ///     this as soon as SwiftUI reports real geometry; a headless driver keeps
  ///     it, which is why the profile's viewport count is the honest default.
  ///   - holds: Which durable leases to register.
  ///   - sink: Where held reactions deposit what they read.
  public init(
    name: String = "Storefront",
    service: StorefrontService,
    initialWindow: RowWindow,
    holds: Holds = [.account],
    sink: StorefrontSink
  ) {
    self.name = name
    self.service = service
    self.initialWindow = initialWindow
    self.holds = holds
    self.sink = sink
  }

  /// Installs initial state and registers the requested leases.
  ///
  /// - Parameter m: This mechanism's whole relationship with the graph.
  public func operate(_ m: MechanismController) {
    m.installStorefrontService(service)
    m.scrollRows(to: initialWindow)

    let sink = sink

    if holds.contains(.account) {
      // `.run` so the account request is demanded during bootstrap and the
      // resting `nil` is written through immediately, rather than the first
      // screen having to trigger it.
      m.watch(storefrontAccountCog, initial: .run, name: "account") { [weak m] _, shopper in
        sink.recordAccount()
        m?.signIn(as: shopper)
      }
    }

    if holds.contains(.browse) {
      m.run { c in
        let visibleProducts = c[storefrontVisibleProductIDsCog]
        var checksum = 0
        for id in visibleProducts {
          let productRow = c[storefrontProductRowCogs[id]]
          checksum = StorefrontKernels.mix(checksum, id.raw)
          checksum = StorefrontKernels.mix(checksum, productRow.priceCents)
          checksum = StorefrontKernels.mix(checksum, productRow.availableUnits)
          checksum = StorefrontKernels.mix(checksum, productRow.badges.rawValue)
          checksum = StorefrontKernels.mix(checksum, productRow.cartQuantity)
        }
        // Reading the prefetch margin is what starts its rows' inventory and
        // offer requests. A list that demanded only what is on screen would
        // show a price arriving one frame after the row it belongs to.
        let prefetchProducts = c[storefrontPrefetchProductIDsCog]
        for id in prefetchProducts {
          _ = c[storefrontProductRowCogs[id]]
        }
        sink.recordBrowse(
          visible: visibleProducts,
          demanded: prefetchProducts,
          checksum: checksum
        )
      }
    }

    if holds.contains(.search) {
      m.run { c in
        let storefrontSuggestions = c[storefrontSuggestionsCog]
        sink.recordSearch(suggestions: storefrontSuggestions)
      }
    }

    if holds.contains(.cart) {
      m.run { c in
        let orderTotal = c[storefrontOrderTotalCog]
        let checkoutReadiness = c[storefrontCheckoutReadinessCog]
        sink.recordCart(total: orderTotal, readiness: checkoutReadiness)
      }
    }

    if holds.contains(.detail) {
      m.run { c in
        // Reading nothing else when no product is open is what lets the detail
        // payload and the recommendation shelf be *released* after the shopper
        // navigates away and their grace elapses.
        let selectedProduct = c[selectedProductCog]
        guard let selectedProduct else {
          sink.recordDetail(reviewCount: 0, recommendations: [])
          return
        }
        let storefrontDetail = c[storefrontDetailCogs[selectedProduct]]
        let storefrontRecommendations = c[storefrontRecommendationsCog]
        sink.recordDetail(
          reviewCount: storefrontDetail.reviewCount,
          recommendations: storefrontRecommendations
        )
      }
    }
  }
}
