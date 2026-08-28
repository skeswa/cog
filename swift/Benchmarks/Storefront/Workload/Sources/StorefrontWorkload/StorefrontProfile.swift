/// How large the Storefront workload is, and every number derived from that.
///
/// This is a documented **representative workload v1**, not a claim about a
/// typical app. Every shape count is configurable and stored here. Checkpoints
/// derive expectations from these values instead of copying observed results.
///
/// The three profiles serve different jobs:
///
/// - ``smoke`` checks correctness and launch on each pull request.
/// - ``standard`` provides reported and gated results.
/// - ``stress`` checks larger scale and deeper pricing in local or nightly runs.
///
/// `Sendable` and `nonisolated` let the service actor and benchmark closure carry
/// this value across isolation. Its `Int` fields share no mutable state.
public nonisolated struct StorefrontProfile: Sendable, Equatable {
  /// The profile's name, used in benchmark labels and failure messages.
  public let name: String

  /// Products in the fixture catalog.
  public let productCount: Int

  /// Categories those products are distributed across.
  ///
  /// Distribution is deterministic and even to within one product, so a
  /// category filter's result size is a function of these two numbers rather
  /// than of the fixture generator's mood.
  public let categoryCount: Int

  /// Variants each product offers.
  ///
  /// Every product has the same number, which is what lets a variant selection
  /// be a pure function of a product identifier and an index.
  public let variantCount: Int

  /// Distinct product rows the standard interaction trace visits.
  ///
  /// This is the number that decides how much keyed state the session
  /// actually creates: a row visit demands inventory, an offer, a pricing
  /// ladder, and a row value for one product identifier.
  public let visitedRowCount: Int

  /// Rows the pinned UI configuration keeps materialized at once.
  ///
  /// The headless driver treats this as the window it slides; the application
  /// pins its row height and device so that the same number of rows is
  /// actually on screen. It is *approximately* the visible count in the app
  /// and *exactly* the window size in the headless driver, and the two are
  /// deliberately not conflated: only one of them can be exact.
  public let viewportRowCount: Int

  /// Rows fetched ahead of the viewport in either scroll direction.
  public let prefetchMargin: Int

  /// Price books the pricing pipeline evaluates.
  ///
  /// One in ``smoke`` and ``standard``, retail. ``stress`` adds member and
  /// wholesale books, which is how it reaches a substantially deeper pipeline
  /// without inventing padding stages: a third book is a third real ladder
  /// over a different base price, and the effective price is the best book the
  /// shopper qualifies for.
  public let priceBookCount: Int

  /// Policies applied, in order, within one price book.
  ///
  /// Never longer than ``StorefrontPricingPolicy/ladder``. A shorter profile
  /// takes a prefix of that ladder, and every policy in the prefix does real
  /// work; nothing is stubbed to reach a count.
  public let pricingPolicyCount: Int

  /// Search suggestions the async suggestion service returns.
  public let suggestionCount: Int

  /// Recommendations the async recommender returns.
  public let recommendationCount: Int

  /// Products the standard trace puts in the cart.
  public let cartProductCount: Int

  /// Products the deterministic inventory burst touches.
  ///
  /// Deliberately larger than ``viewportRowCount``, because the burst's whole
  /// purpose is to contain both visible and offscreen products so a checkpoint
  /// can prove the offscreen half invalidated nothing on screen.
  public let inventoryBurstCount: Int

  /// The total number of meaningful transformations in the pricing pipeline.
  ///
  /// Derived rather than stored: a pipeline depth that could disagree with the
  /// policies and books that produce it would make the shape assertion a
  /// tautology.
  public var pricingStageCount: Int { priceBookCount * pricingPolicyCount }

  /// Creates a profile from its parameters.
  ///
  /// Public so a local experiment can name a size the three shipped profiles
  /// do not, without editing this file. Nothing validates the combination
  /// here; ``StorefrontShape`` is where a workload proves the graph it built
  /// matches the profile it was given.
  public init(
    name: String,
    productCount: Int,
    categoryCount: Int,
    variantCount: Int,
    visitedRowCount: Int,
    viewportRowCount: Int,
    prefetchMargin: Int,
    priceBookCount: Int,
    pricingPolicyCount: Int,
    suggestionCount: Int,
    recommendationCount: Int,
    cartProductCount: Int,
    inventoryBurstCount: Int
  ) {
    self.name = name
    self.productCount = productCount
    self.categoryCount = categoryCount
    self.variantCount = variantCount
    self.visitedRowCount = visitedRowCount
    self.viewportRowCount = viewportRowCount
    self.prefetchMargin = prefetchMargin
    self.priceBookCount = priceBookCount
    self.pricingPolicyCount = pricingPolicyCount
    self.suggestionCount = suggestionCount
    self.recommendationCount = recommendationCount
    self.cartProductCount = cartProductCount
    self.inventoryBurstCount = inventoryBurstCount
  }

  /// The fast profile: correctness, and the pull-request UI coverage.
  ///
  /// Small enough for fast simulator and package tests. It still includes
  /// several categories, four pricing policies, cart promotions, and both
  /// halves of an inventory burst.
  public static let smoke = StorefrontProfile(
    name: "smoke",
    productCount: 120,
    categoryCount: 6,
    variantCount: 3,
    visitedRowCount: 24,
    viewportRowCount: 12,
    prefetchMargin: 4,
    priceBookCount: 1,
    pricingPolicyCount: 4,
    suggestionCount: 5,
    recommendationCount: 6,
    cartProductCount: 3,
    inventoryBurstCount: 24
  )

  /// The representative workload v1, and the only profile whose numbers are
  /// reported.
  ///
  /// The scale is an explicit choice rather than a measurement of real apps:
  /// 1,200 products over 24 categories, 120 distinct rows visited in one
  /// session, about 30 rows materialized at a time, and a 16-policy pricing
  /// ladder. `impl/perf.md` records what it covers and, just as importantly, what
  /// it does not.
  public static let standard = StorefrontProfile(
    name: "standard",
    productCount: 1_200,
    categoryCount: 24,
    variantCount: 4,
    visitedRowCount: 120,
    viewportRowCount: 30,
    prefetchMargin: 8,
    priceBookCount: 1,
    pricingPolicyCount: 16,
    suggestionCount: 8,
    recommendationCount: 12,
    cartProductCount: 3,
    inventoryBurstCount: 96
  )

  /// The local and nightly profile: several times the size, and a pipeline
  /// three price books deep.
  ///
  /// Not reported and not gated. It exists to find the cliff, the point where
  /// a linear-looking cost stops being linear, which a profile sized to be
  /// comfortable can never do.
  public static let stress = StorefrontProfile(
    name: "stress",
    productCount: 6_000,
    categoryCount: 48,
    variantCount: 6,
    visitedRowCount: 400,
    viewportRowCount: 40,
    prefetchMargin: 12,
    priceBookCount: 3,
    pricingPolicyCount: 16,
    suggestionCount: 12,
    recommendationCount: 24,
    cartProductCount: 6,
    inventoryBurstCount: 240
  )

  /// Every shipped profile, in increasing size.
  public static let all: [StorefrontProfile] = [.smoke, .standard, .stress]

  /// Looks a shipped profile up by name.
  ///
  /// The application selects its profile from a launch argument and the
  /// benchmark executable from a literal, so both need one place that turns a
  /// string into a profile and refuses anything else.
  ///
  /// - Parameter name: `smoke`, `standard`, or `stress`.
  /// - Returns: The named profile, or `nil` when the name is not one of them.
  public static func named(_ name: String) -> StorefrontProfile? {
    all.first { $0.name == name }
  }
}
