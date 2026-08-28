/// The Storefront domain vocabulary: identifiers, catalog values, and the
/// shapes a screen actually renders.
///
/// Everything here is a plain value type and nothing here knows about Cog.
/// That separation is deliberate and load-bearing: the compute-only control
/// benchmark runs the same algorithms over the same values with no graph at
/// all, and it can only do that if the domain model has no graph in it.
///
/// Money is integer **cents** everywhere, never `Double`. A checkpoint that
/// promises an exact total cannot keep that promise in binary floating point,
/// and a pricing pipeline sixteen multiplications deep is exactly the shape
/// that turns a rounding choice into a visible defect.
public nonisolated enum StorefrontMoney {
  /// Rounds a cent amount scaled by a basis-point factor, half away from zero.
  ///
  /// Every policy in the pricing ladder that scales a price routes through
  /// here, so the whole pipeline has one rounding rule rather than sixteen
  /// accidental ones. Half-away-from-zero rather than banker's rounding
  /// because that is what a price tag does.
  ///
  /// - Parameters:
  ///   - cents: The amount to scale.
  ///   - basisPoints: The factor, in hundredths of a percent. 10,000 is
  ///     identity; 9,250 is a 7.5% discount.
  /// - Returns: The scaled amount, rounded to whole cents.
  public static func scaled(_ cents: Int, byBasisPoints basisPoints: Int) -> Int {
    let numerator = cents * basisPoints
    let half = numerator < 0 ? -5_000 : 5_000
    return (numerator + half) / 10_000
  }
}

/// A product's stable identity.
///
/// A distinct type rather than a bare `Int` because it is a keyed
/// declaration's key, a `ForEach` identity, and a checkpoint's vocabulary all
/// at once, and confusing it with a row index or a category ordinal is the
/// classic way a list benchmark starts measuring the wrong thing.
public nonisolated struct ProductID: Hashable, Sendable, Comparable, CustomStringConvertible {
  /// The dense zero-based ordinal the fixture generator assigns.
  public let raw: Int

  /// Creates an identifier from its ordinal.
  public init(_ raw: Int) {
    self.raw = raw
  }

  /// Orders product identifiers by their fixture ordinal.
  public static func < (lhs: ProductID, rhs: ProductID) -> Bool {
    lhs.raw < rhs.raw
  }

  /// The trace label `p` followed by the fixture ordinal.
  public var description: String { "p\(raw)" }
}

/// A category's stable identity.
public nonisolated struct CategoryID: Hashable, Sendable, Comparable, CustomStringConvertible {
  /// The dense zero-based ordinal the fixture generator assigns.
  public let raw: Int

  /// Creates an identifier from its ordinal.
  public init(_ raw: Int) {
    self.raw = raw
  }

  /// Orders category identifiers by their fixture ordinal.
  public static func < (lhs: CategoryID, rhs: CategoryID) -> Bool {
    lhs.raw < rhs.raw
  }

  /// The trace label `c` followed by the fixture ordinal.
  public var description: String { "c\(raw)" }
}

/// One variant of a product, a size, a colourway, a capacity.
///
/// Variants carry their own price delta and their own stock, which is what
/// makes selecting one a write that genuinely changes downstream pricing and
/// availability rather than a cosmetic toggle.
public nonisolated struct ProductVariant: Hashable, Sendable {
  /// The variant's index within its product, `0..<profile.variantCount`.
  public let index: Int

  /// Human-readable name, used by the application's picker.
  public let name: String

  /// Cents added to (or removed from) the product's list price.
  public let priceDeltaCents: Int

  /// Units of this variant the catalog believes exist, before live inventory.
  public let catalogStock: Int

  /// Creates a variant.
  public init(index: Int, name: String, priceDeltaCents: Int, catalogStock: Int) {
    self.index = index
    self.name = name
    self.priceDeltaCents = priceDeltaCents
    self.catalogStock = catalogStock
  }
}

/// A catalog product, exactly as the catalog service returns it.
public nonisolated struct Product: Hashable, Sendable, Identifiable {
  /// Stable identity, and the key of every per-product declaration.
  public let id: ProductID

  /// Display name, and the text the search index tokenizes.
  public let name: String

  /// The category this product is filed under.
  public let category: CategoryID

  /// Retail list price in cents, before any pricing policy.
  public let listPriceCents: Int

  /// Wholesale base in cents, the second price book's starting point.
  public let wholesaleBaseCents: Int

  /// The product's variants, always `profile.variantCount` of them.
  public let variants: [ProductVariant]

  /// A fixed-dimensional feature vector used by ranking and recommendations.
  ///
  /// Eight signed dimensions, popularity, margin, freshness, rating,
  /// return rate, seasonality, breadth, and price band, held as a fixed-size
  /// array so scoring is a dot product with no allocation and no branching on
  /// length.
  public let features: StorefrontFeatureVector

  /// Search tokens, precomputed once by the fixture generator.
  ///
  /// Precomputed because tokenizing a product name is catalog work, not query
  /// work, and doing it per query would put fixture cost inside the measured
  /// region of every search interaction.
  public let tokens: [String]

  /// Creates a product.
  public init(
    id: ProductID,
    name: String,
    category: CategoryID,
    listPriceCents: Int,
    wholesaleBaseCents: Int,
    variants: [ProductVariant],
    features: StorefrontFeatureVector,
    tokens: [String]
  ) {
    self.id = id
    self.name = name
    self.category = category
    self.listPriceCents = listPriceCents
    self.wholesaleBaseCents = wholesaleBaseCents
    self.variants = variants
    self.features = features
    self.tokens = tokens
  }
}

/// A fixed eight-dimensional score vector.
///
/// Eight named `Int32`s rather than an `[Int]`, so a dot product over a
/// thousand products allocates nothing and every product's vector is the same
/// size by construction.
public nonisolated struct StorefrontFeatureVector: Hashable, Sendable {
  /// Popularity.
  public let popularity: Int32
  /// Margin.
  public let margin: Int32
  /// Freshness; also what the "newest" sort orders by.
  public let freshness: Int32
  /// Average rating.
  public let rating: Int32
  /// Return rate, which the weighting penalizes.
  public let returnRate: Int32
  /// Seasonality.
  public let seasonality: Int32
  /// Assortment breadth.
  public let breadth: Int32
  /// Price band.
  public let priceBand: Int32

  /// Creates a vector from its eight dimensions, in the order above.
  public init(
    _ popularity: Int32,
    _ margin: Int32,
    _ freshness: Int32,
    _ rating: Int32,
    _ returnRate: Int32,
    _ seasonality: Int32,
    _ breadth: Int32,
    _ priceBand: Int32
  ) {
    self.popularity = popularity
    self.margin = margin
    self.freshness = freshness
    self.rating = rating
    self.returnRate = returnRate
    self.seasonality = seasonality
    self.breadth = breadth
    self.priceBand = priceBand
  }

  /// The dot product of two vectors.
  ///
  /// Written out rather than looped: eight multiply-adds with no bounds checks
  /// is the arithmetic the compute-only control is supposed to be measuring,
  /// and eight stored properties rather than an array is what keeps a
  /// thousand-product scoring pass allocation-free.
  public static func dot(_ lhs: StorefrontFeatureVector, _ rhs: StorefrontFeatureVector) -> Int {
    Int(lhs.popularity) * Int(rhs.popularity)
      + Int(lhs.margin) * Int(rhs.margin)
      + Int(lhs.freshness) * Int(rhs.freshness)
      + Int(lhs.rating) * Int(rhs.rating)
      + Int(lhs.returnRate) * Int(rhs.returnRate)
      + Int(lhs.seasonality) * Int(rhs.seasonality)
      + Int(lhs.breadth) * Int(rhs.breadth)
      + Int(lhs.priceBand) * Int(rhs.priceBand)
  }
}

/// A category as the filter chips render it.
public nonisolated struct Category: Hashable, Sendable, Identifiable {
  /// Stable identity.
  public let id: CategoryID

  /// Display name.
  public let name: String

  /// Creates a category.
  public init(id: CategoryID, name: String) {
    self.id = id
    self.name = name
  }
}

/// Everything the catalog service returns in one response.
///
/// One value rather than several async cogs because a catalog fetch is one
/// request in every real storefront, and splitting it would invent async
/// states the application does not have.
public nonisolated struct CatalogSnapshot: Hashable, Sendable {
  /// Every product, in identifier order.
  public let products: [Product]

  /// Every category, in identifier order.
  public let categories: [Category]

  /// An empty snapshot: what a catalog-backed read rests on before the first
  /// accepted response.
  public static let empty = CatalogSnapshot(products: [], categories: [])

  /// Creates a snapshot.
  public init(products: [Product], categories: [Category]) {
    self.products = products
    self.categories = categories
  }
}

/// How the shopper wants results ordered.
public nonisolated enum SortMode: String, Hashable, Sendable, CaseIterable {
  /// Best match for the current query, then popularity.
  case relevance
  /// Cheapest effective price first.
  case priceAscending
  /// Most expensive effective price first.
  case priceDescending
  /// Newest first, by the freshness feature.
  case newest

  /// Display name for the sort menu.
  public var displayName: String {
    switch self {
    case .relevance: "Best match"
    case .priceAscending: "Price: low to high"
    case .priceDescending: "Price: high to low"
    case .newest: "Newest"
    }
  }
}

/// The shopper's membership tier, which several pricing policies read.
public nonisolated enum MembershipTier: Int, Hashable, Sendable, Comparable, CaseIterable {
  /// A shopper without a registered account.
  case guest = 0
  /// A registered shopper on the free plan.
  case member = 1
  /// A registered shopper on the paid plan.
  case plus = 2

  /// Orders tiers from guest through plus.
  public static func < (lhs: MembershipTier, rhs: MembershipTier) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// The signed-in shopper, or the absence of one.
public nonisolated struct Shopper: Hashable, Sendable {
  /// Stable account identifier, and the seed of the personalization vector.
  public let accountID: Int

  /// Display name.
  public let name: String

  /// Membership tier.
  public let tier: MembershipTier

  /// The taste vector recommendations score the catalog against.
  public let taste: StorefrontFeatureVector

  /// Loyalty points, which one pricing policy converts into a discount.
  public let loyaltyPoints: Int

  /// Creates a shopper.
  public init(
    accountID: Int,
    name: String,
    tier: MembershipTier,
    taste: StorefrontFeatureVector,
    loyaltyPoints: Int
  ) {
    self.accountID = accountID
    self.name = name
    self.tier = tier
    self.taste = taste
    self.loyaltyPoints = loyaltyPoints
  }
}

/// Where the order ships, which decides the tax region and one pricing policy.
public nonisolated struct ShippingAddress: Hashable, Sendable {
  /// The market this address belongs to, `0..<StorefrontFixtures.marketCount`.
  public let market: Int

  /// Postal code, carried so a quote request has something to key on.
  public let postalCode: String

  /// Creates an address.
  public init(market: Int, postalCode: String) {
    self.market = market
    self.postalCode = postalCode
  }
}

/// How the order ships.
public nonisolated enum ShippingMethod: String, Hashable, Sendable, CaseIterable {
  /// The lowest base rate and the only method eligible for free shipping.
  case standard
  /// A two-day base quote priced above standard shipping.
  case express
  /// A one-day base quote with the highest base rate.
  case overnight

  /// Display name for the shipping picker.
  public var displayName: String {
    switch self {
    case .standard: "Standard"
    case .express: "Express"
    case .overnight: "Overnight"
    }
  }
}

/// A coupon the shopper has applied, as the shopper typed it.
///
/// Validation is an automatic value, not a property of this type: a coupon code
/// is a string until the promotion optimizer has seen the cart, and modelling
/// it as pre-validated would move real work out of the graph.
public nonisolated struct CouponCode: Hashable, Sendable {
  /// The raw code.
  public let raw: String

  /// Creates a code.
  public init(_ raw: String) {
    self.raw = raw
  }
}

/// Live availability for one product, as the inventory service reports it.
public nonisolated struct InventoryReading: Hashable, Sendable {
  /// Units on hand per variant index.
  public let unitsByVariant: [Int]

  /// Whether the warehouse considers this product restockable.
  public let restockable: Bool

  /// A reading that reports nothing: what an inventory read rests on before
  /// the first accepted response.
  public static let unknown = InventoryReading(unitsByVariant: [], restockable: false)

  /// Creates a reading.
  public init(unitsByVariant: [Int], restockable: Bool) {
    self.unitsByVariant = unitsByVariant
    self.restockable = restockable
  }

  /// Units available for one variant, or zero when the reading does not cover
  /// it.
  ///
  /// - Parameter variant: The variant index to read.
  /// - Returns: Units on hand, or zero.
  public func units(forVariant variant: Int) -> Int {
    guard variant >= 0, variant < unitsByVariant.count else { return 0 }
    return unitsByVariant[variant]
  }
}

/// A personalized offer for one product, as the offer service returns it.
public nonisolated struct PersonalizedOffer: Hashable, Sendable {
  /// The discount, in basis points off the price the ladder produced.
  public let discountBasisPoints: Int

  /// Why the shopper is being shown this, used by the badge.
  public let reason: String

  /// No offer: what an offer read rests on before the first accepted response.
  public static let none = PersonalizedOffer(discountBasisPoints: 0, reason: "")

  /// Creates an offer.
  public init(discountBasisPoints: Int, reason: String) {
    self.discountBasisPoints = discountBasisPoints
    self.reason = reason
  }
}

/// The detail-screen payload for one product.
public nonisolated struct ProductDetail: Hashable, Sendable {
  /// Long-form description.
  public let summary: String

  /// Reviews counted.
  public let reviewCount: Int

  /// Average rating in hundredths of a star, so it stays an integer.
  public let averageRatingHundredths: Int

  /// An empty detail: what a detail read rests on before its first response.
  public static let empty = ProductDetail(summary: "", reviewCount: 0, averageRatingHundredths: 0)

  /// Creates a detail payload.
  public init(summary: String, reviewCount: Int, averageRatingHundredths: Int) {
    self.summary = summary
    self.reviewCount = reviewCount
    self.averageRatingHundredths = averageRatingHundredths
  }
}

/// A shipping quote for the current cart, address, and method.
public nonisolated struct ShippingQuote: Hashable, Sendable {
  /// Shipping cost in cents.
  public let costCents: Int

  /// Business days until delivery.
  public let estimatedDays: Int

  /// The zero quote a cart rests on before its first accepted response.
  public static let pending = ShippingQuote(costCents: 0, estimatedDays: 0)

  /// Creates a quote.
  public init(costCents: Int, estimatedDays: Int) {
    self.costCents = costCents
    self.estimatedDays = estimatedDays
  }
}

/// A tax quote for the current discounted subtotal and address.
public nonisolated struct TaxQuote: Hashable, Sendable {
  /// Tax in cents.
  public let taxCents: Int

  /// The effective rate in basis points, shown in the cart's breakdown.
  public let rateBasisPoints: Int

  /// The zero quote a cart rests on before its first accepted response.
  public static let pending = TaxQuote(taxCents: 0, rateBasisPoints: 0)

  /// Creates a quote.
  public init(taxCents: Int, rateBasisPoints: Int) {
    self.taxCents = taxCents
    self.rateBasisPoints = rateBasisPoints
  }
}

/// One promotion the optimizer may or may not apply.
public nonisolated struct Promotion: Hashable, Sendable, Identifiable {
  /// Stable identity, and the coupon code that names it.
  public let id: String

  /// Categories the promotion applies to; empty means the whole cart.
  public let categories: Set<CategoryID>

  /// Minimum qualifying subtotal in cents.
  public let minimumSubtotalCents: Int

  /// Discount in basis points off the qualifying amount.
  public let discountBasisPoints: Int

  /// Promotions this one cannot be combined with.
  ///
  /// This is what makes promotion selection a real optimization rather than a
  /// sum: with exclusions, the best set is not the set of individually best
  /// promotions.
  public let excludes: Set<String>

  /// Creates a promotion.
  public init(
    id: String,
    categories: Set<CategoryID>,
    minimumSubtotalCents: Int,
    discountBasisPoints: Int,
    excludes: Set<String>
  ) {
    self.id = id
    self.categories = categories
    self.minimumSubtotalCents = minimumSubtotalCents
    self.discountBasisPoints = discountBasisPoints
    self.excludes = excludes
  }
}

/// The set of promotions the optimizer chose, and what they are worth.
public nonisolated struct PromotionPlan: Hashable, Sendable {
  /// The chosen promotion identifiers, in identifier order.
  public let appliedIDs: [String]

  /// Total discount in cents.
  public let discountCents: Int

  /// Nothing applied.
  public static let none = PromotionPlan(appliedIDs: [], discountCents: 0)

  /// Creates a plan.
  public init(appliedIDs: [String], discountCents: Int) {
    self.appliedIDs = appliedIDs
    self.discountCents = discountCents
  }
}

/// One line of the cart, as the cart screen renders it.
public nonisolated struct CartLine: Hashable, Sendable, Identifiable {
  /// The product on this line, and the line's identity.
  public var id: ProductID { productID }

  /// The product on this line.
  public let productID: ProductID

  /// Display name, so a row need not read the catalog a second time.
  public let name: String

  /// The selected variant's index.
  public let variantIndex: Int

  /// How many the shopper wants.
  public let quantity: Int

  /// The per-unit price the pricing pipeline produced, in cents.
  public let unitPriceCents: Int

  /// Whether live inventory can satisfy the requested quantity.
  public let inStock: Bool

  /// Quantity times unit price.
  public var extendedCents: Int { quantity * unitPriceCents }

  /// Creates a line.
  public init(
    productID: ProductID,
    name: String,
    variantIndex: Int,
    quantity: Int,
    unitPriceCents: Int,
    inStock: Bool
  ) {
    self.productID = productID
    self.name = name
    self.variantIndex = variantIndex
    self.quantity = quantity
    self.unitPriceCents = unitPriceCents
    self.inStock = inStock
  }
}

/// The badges a product row shows.
///
/// An `OptionSet` rather than an array so that a badge change is a scalar
/// comparison and an equality-gated declaration can stop an invalidation wave
/// on it without allocating.
public nonisolated struct ProductBadges: OptionSet, Hashable, Sendable {
  /// The bit field that stores the selected badges.
  public let rawValue: Int

  /// Creates a badge set from its bit field.
  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// The price the ladder produced is below the list price.
  public static let onSale = ProductBadges(rawValue: 1 << 0)
  /// Live inventory reports few units left.
  public static let lowStock = ProductBadges(rawValue: 1 << 1)
  /// Live inventory reports none, and the warehouse cannot restock.
  public static let soldOut = ProductBadges(rawValue: 1 << 2)
  /// A personalized offer applies.
  public static let offer = ProductBadges(rawValue: 1 << 3)
  /// The shopper has favorited this product.
  public static let favorite = ProductBadges(rawValue: 1 << 4)
  /// The shopper viewed this product earlier in the session.
  public static let recentlyViewed = ProductBadges(rawValue: 1 << 5)
  /// The product is in the cart.
  public static let inCart = ProductBadges(rawValue: 1 << 6)
}

/// Everything one product row renders, and nothing more.
///
/// A row value exists because a list row should read **one** automatic value and
/// map it to views, not read nine. That is not a projection type in the sense
/// the conventions forbid: it is a genuinely automatic value with its own
/// equality, computed by a keyed declaration, and a row that reads it depends
/// on the row rather than on nine unrelated things.
public nonisolated struct ProductRow: Hashable, Sendable, Identifiable {
  /// The product, and the row's `ForEach` identity.
  public var id: ProductID { productID }

  /// The product this row is for.
  public let productID: ProductID

  /// Display name.
  public let name: String

  /// The category chip's text.
  public let categoryName: String

  /// The price the pricing pipeline produced, in cents.
  public let priceCents: Int

  /// The list price, shown struck through when it differs.
  public let listPriceCents: Int

  /// Units live inventory reports for the selected variant.
  public let availableUnits: Int

  /// Badges.
  public let badges: ProductBadges

  /// How many of this product are in the cart.
  public let cartQuantity: Int

  /// Creates a row.
  public init(
    productID: ProductID,
    name: String,
    categoryName: String,
    priceCents: Int,
    listPriceCents: Int,
    availableUnits: Int,
    badges: ProductBadges,
    cartQuantity: Int
  ) {
    self.productID = productID
    self.name = name
    self.categoryName = categoryName
    self.priceCents = priceCents
    self.listPriceCents = listPriceCents
    self.availableUnits = availableUnits
    self.badges = badges
    self.cartQuantity = cartQuantity
  }
}

/// One section of the browse list.
public nonisolated struct StorefrontSection: Hashable, Sendable, Identifiable {
  /// Stable identity: the category, or `nil` for the cross-category top band.
  public var id: CategoryID? { category }

  /// The category this section groups, or `nil` for best matches overall.
  public let category: CategoryID?

  /// Section header text.
  public let title: String

  /// The products in this section, in rank order.
  public let productIDs: [ProductID]

  /// Creates a section.
  public init(category: CategoryID?, title: String, productIDs: [ProductID]) {
    self.category = category
    self.title = title
    self.productIDs = productIDs
  }
}

/// The window of rows the list has materialized.
///
/// A value rather than two sources, because a scroll moves both ends at once
/// and two sources would let a turn observe half a scroll.
public nonisolated struct RowWindow: Hashable, Sendable {
  /// Index of the first materialized row within the flattened section list.
  public let offset: Int

  /// How many rows are materialized.
  public let length: Int

  /// Creates a window.
  public init(offset: Int, length: Int) {
    self.offset = offset
    self.length = length
  }
}

/// Whether the cart can be checked out, and why not when it cannot.
public nonisolated struct CheckoutReadiness: Hashable, Sendable {
  /// Whether every requirement is met.
  public let isReady: Bool

  /// Human-readable blockers, in a stable order.
  public let blockers: [String]

  /// Creates a readiness value.
  public init(isReady: Bool, blockers: [String]) {
    self.isReady = isReady
    self.blockers = blockers
  }
}

/// The cart's money, fully broken down.
public nonisolated struct OrderTotal: Hashable, Sendable {
  /// Sum of every line's extended price.
  public let subtotalCents: Int

  /// What the promotion plan took off.
  public let discountCents: Int

  /// Subtotal minus discount.
  public let discountedSubtotalCents: Int

  /// The accepted tax quote's tax.
  public let taxCents: Int

  /// The accepted shipping quote's cost.
  public let shippingCents: Int

  /// Everything, added up.
  public var totalCents: Int { discountedSubtotalCents + taxCents + shippingCents }

  /// Creates a total.
  public init(
    subtotalCents: Int,
    discountCents: Int,
    discountedSubtotalCents: Int,
    taxCents: Int,
    shippingCents: Int
  ) {
    self.subtotalCents = subtotalCents
    self.discountCents = discountCents
    self.discountedSubtotalCents = discountedSubtotalCents
    self.taxCents = taxCents
    self.shippingCents = shippingCents
  }
}
