/// The deterministic world the Storefront workload runs against.
///
/// Everything here is a pure function of a profile and a fixed seed. There is
/// no network, no `Date`, no `Task.sleep`, and no unseeded randomness anywhere
/// in this package, because a benchmark whose inputs move cannot tell a
/// regression from a Tuesday. Two calls to ``catalog(for:)`` with the same
/// profile produce byte-identical products in the same order, on any machine.
///
/// The generator is `nonisolated` and allocation-light so the compute-only
/// control benchmark can build the same inputs the graph-backed workload uses
/// without paying for a `Cogs` to do it.
public nonisolated enum StorefrontFixtures {
  /// The seed every fixture derives from.
  ///
  /// A constant rather than a parameter: a seed that a caller could change is
  /// a seed a caller will change, and then two results stop being comparable
  /// without anyone noticing.
  public static let seed: UInt64 = 0x5F37_5A86_C0FF_EE01

  /// How many shipping markets exist.
  ///
  /// Four, so regional pricing and tax have something to vary over without
  /// the market becoming the dominant axis of the fixture.
  public static let marketCount = 4

  /// The most promotions the optimizer will ever consider.
  ///
  /// The promotion search is exponential in this number, so it is a hard cap
  /// rather than a suggestion: twelve promotions is 4,096 subsets, which is
  /// real work a cart interaction can afford, and thirteen would be the start
  /// of a slippery slope.
  public static let maximumPromotions = 12

  // MARK: - Deterministic generation

  /// SplitMix64, the whole random source of this package.
  ///
  /// Chosen because it is four lines, has no state beyond one `UInt64`, and
  /// produces the same stream on every platform, which `SystemRandomNumberGenerator`
  /// explicitly does not, and which is the entire requirement here.
  struct Generator {
    /// The running state.
    private var state: UInt64

    /// Creates a generator from a seed.
    init(seed: UInt64) {
      state = seed
    }

    /// The next value in the stream.
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }

    /// The next value in `0..<bound`.
    ///
    /// - Parameter bound: Exclusive upper bound; must be positive.
    /// - Returns: A value in `0..<bound`.
    mutating func next(upTo bound: Int) -> Int {
      precondition(bound > 0, "a bound must be positive")
      return Int(next() % UInt64(bound))
    }

    /// The next value in `lower...upper`.
    mutating func next(in range: ClosedRange<Int>) -> Int {
      range.lowerBound + next(upTo: range.count)
    }
  }

  // MARK: - Vocabulary

  /// Leading words of a product name; also the tokens a query matches on.
  ///
  /// `trail` is first because the standard interaction trace types
  /// "trail shoes" one character at a time, and a query that matched nothing
  /// would exercise the empty-result path rather than the ranking path.
  static let qualifiers = [
    "trail", "alpine", "summit", "river", "canyon", "ridge", "tundra", "coastal",
  ]

  /// Material words, the middle of a product name.
  static let materials = [
    "merino", "ripstop", "titanium", "cordura", "gore", "carbon", "canvas", "down",
  ]

  /// Product nouns; the last word of a name and the strongest search token.
  static let nouns = [
    "shoes", "jacket", "pack", "tent", "bottle", "gloves", "beanie", "socks",
    "lamp", "stove", "rope", "axe", "skis", "board", "paddle", "chair",
  ]

  /// Category names, cycled and suffixed when a profile wants more than these.
  static let categoryNames = [
    "Footwear", "Outerwear", "Packs", "Shelter", "Hydration", "Handwear",
    "Headwear", "Socks", "Lighting", "Cooking", "Climbing", "Tools",
    "Snow", "Water", "Camp", "Navigation", "Repair", "Nutrition",
    "Optics", "Electronics", "Safety", "Dog", "Kids", "Sale",
  ]

  /// Variant names, cycled.
  static let variantNames = ["Small", "Medium", "Large", "X-Large", "Regular", "Tall"]

  // MARK: - Catalog

  /// Builds the whole catalog for a profile.
  ///
  /// Products are laid out so that every downstream expectation is arithmetic
  /// rather than observation: product `i` belongs to category `i % categoryCount`,
  /// so a category filter selects a known count; names cycle through the
  /// vocabulary at coprime strides, so token frequencies are stable; and
  /// prices are drawn from the generator in a fixed order, so the catalog is
  /// the same sequence of bytes every time.
  ///
  /// - Parameter profile: The size to build.
  /// - Returns: A snapshot with `profile.productCount` products in identifier
  ///   order and `profile.categoryCount` categories in identifier order.
  public static func catalog(for profile: StorefrontProfile) -> CatalogSnapshot {
    var generator = Generator(seed: seed)

    let categories = (0..<profile.categoryCount).map { index in
      Category(id: CategoryID(index), name: categoryName(index))
    }

    var products: [Product] = []
    products.reserveCapacity(profile.productCount)

    for index in 0..<profile.productCount {
      let qualifier = qualifiers[(index * 3) % qualifiers.count]
      let material = materials[(index * 5) % materials.count]
      let noun = nouns[(index * 7) % nouns.count]
      let categoryIndex = index % profile.categoryCount
      let name = "\(capitalized(qualifier)) \(capitalized(material)) \(capitalized(noun)) \(index)"

      let listPriceCents = generator.next(in: 1_995...49_995)
      let wholesaleBaseCents = StorefrontMoney.scaled(listPriceCents, byBasisPoints: 6_200)

      var variants: [ProductVariant] = []
      variants.reserveCapacity(profile.variantCount)
      for variantIndex in 0..<profile.variantCount {
        variants.append(
          ProductVariant(
            index: variantIndex,
            name: variantNames[variantIndex % variantNames.count],
            priceDeltaCents: generator.next(in: -500...1_500),
            catalogStock: generator.next(in: 0...40)
          )
        )
      }

      let features = StorefrontFeatureVector(
        Int32(generator.next(in: 0...100)),
        Int32(generator.next(in: 0...100)),
        Int32(generator.next(in: 0...100)),
        Int32(generator.next(in: 0...100)),
        Int32(generator.next(in: -50...50)),
        Int32(generator.next(in: 0...100)),
        Int32(generator.next(in: 0...100)),
        Int32(generator.next(in: 0...100))
      )

      products.append(
        Product(
          id: ProductID(index),
          name: name,
          category: CategoryID(categoryIndex),
          listPriceCents: listPriceCents,
          wholesaleBaseCents: wholesaleBaseCents,
          variants: variants,
          features: features,
          tokens: [qualifier, material, noun, categoryName(categoryIndex).lowercased()]
        )
      )
    }

    return CatalogSnapshot(products: products, categories: categories)
  }

  /// Uppercases an ASCII word's first character, without `Foundation`.
  ///
  /// This package imports no `Foundation`, so that a fixture cannot depend on
  /// the host's locale. Product names are ASCII by construction.
  ///
  /// - Parameter word: The word to capitalize.
  /// - Returns: The word with its first character uppercased.
  static func capitalized(_ word: String) -> String {
    guard let first = word.first else { return word }
    return String(first).uppercased() + String(word.dropFirst())
  }

  /// The display name of category `index`.
  ///
  /// Cycles the fixed vocabulary and appends a lap number past the end, so a
  /// profile may ask for more categories than there are names without two
  /// categories sharing one.
  static func categoryName(_ index: Int) -> String {
    let base = categoryNames[index % categoryNames.count]
    let lap = index / categoryNames.count
    return lap == 0 ? base : "\(base) \(lap + 1)"
  }

  // MARK: - Account

  /// The shopper the account service returns.
  ///
  /// One shopper, deterministic, with a taste vector derived from the same
  /// seed so that recommendations are reproducible and non-trivial, a taste
  /// vector of all ones would make every product tie and hide the ranking.
  ///
  /// - Parameter profile: The profile, which decides nothing here today but is
  ///   taken so that a future profile-dependent account does not change the
  ///   call sites.
  /// - Returns: The signed-in shopper.
  public static func shopper(for profile: StorefrontProfile) -> Shopper {
    var generator = Generator(seed: seed &+ 0x51)
    _ = profile
    return Shopper(
      accountID: 4_711,
      name: "Avery Nakamura",
      tier: .plus,
      taste: StorefrontFeatureVector(
        Int32(generator.next(in: -20...60)),
        Int32(generator.next(in: -20...60)),
        Int32(generator.next(in: -20...60)),
        Int32(generator.next(in: -20...60)),
        Int32(generator.next(in: -60...20)),
        Int32(generator.next(in: -20...60)),
        Int32(generator.next(in: -20...60)),
        Int32(generator.next(in: -20...60))
      ),
      loyaltyPoints: 3_250
    )
  }

  /// The address the session starts with.
  public static let startingAddress = ShippingAddress(market: 1, postalCode: "98109")

  /// The address the session switches to, in a different market.
  public static let alternateAddress = ShippingAddress(market: 3, postalCode: "10011")

  /// The coupon the standard trace applies.
  ///
  /// Chosen to be a real promotion identifier, because a coupon that matched
  /// nothing would skip the optimizer entirely.
  public static let sessionCoupon = CouponCode("RIDGE10")

  // MARK: - Promotions

  /// The promotions the optimizer chooses between.
  ///
  /// Exactly ``maximumPromotions`` of them, with a deliberate exclusion web:
  /// the two largest percentage promotions exclude each other, and the
  /// cart-wide promotion excludes every category promotion. Without exclusions
  /// the optimizer would degenerate into "apply everything", which is a sum
  /// rather than a decision.
  ///
  /// - Parameter profile: Supplies the category count the category promotions
  ///   are spread over.
  /// - Returns: Promotions in identifier order.
  public static func promotions(for profile: StorefrontProfile) -> [Promotion] {
    // Built once per shipped profile. The coupon stage of the pricing ladder
    // asks for this list every time it recomputes, and rebuilding twelve
    // promotions with their exclusion sets on every price of every row is
    // fixture cost landing inside a measured region.
    if let cached = shippedPromotions[profile.name] { return cached }
    return makePromotions(for: profile)
  }

  /// Every shipped profile's promotions, built once.
  private static let shippedPromotions: [String: [Promotion]] = Dictionary(
    uniqueKeysWithValues: StorefrontProfile.all.map { ($0.name, makePromotions(for: $0)) }
  )

  /// Builds a profile's promotions from scratch.
  ///
  /// - Parameter profile: Supplies the category count the category promotions
  ///   are spread over.
  /// - Returns: Promotions in identifier order.
  private static func makePromotions(for profile: StorefrontProfile) -> [Promotion] {
    let names = [
      "RIDGE10", "SUMMIT15", "TRAIL05", "CANYON20", "RIVER08", "TUNDRA12",
      "COASTAL06", "ALPINE18", "BUNDLE25", "LOYALTY07", "CLEAROUT30", "WELCOME09",
    ]
    let discounts = [1_000, 1_500, 500, 2_000, 800, 1_200, 600, 1_800, 2_500, 700, 3_000, 900]
    let minimums = [0, 12_000, 0, 30_000, 5_000, 9_000, 0, 25_000, 40_000, 3_000, 60_000, 0]

    return (0..<maximumPromotions).map { index in
      // Every third promotion is cart-wide; the rest bind to two categories
      // each, chosen at a coprime stride so coverage is even.
      let isCartWide = index % 3 == 0
      let categories: Set<CategoryID> =
        isCartWide
        ? []
        : Set([
          CategoryID((index * 5) % profile.categoryCount),
          CategoryID((index * 7 + 1) % profile.categoryCount),
        ])
      // The two deepest promotions are mutually exclusive, and the clearout
      // promotion excludes every cart-wide one.
      var excludes: Set<String> = []
      if names[index] == "CLEAROUT30" {
        excludes = ["BUNDLE25", "CANYON20", "ALPINE18"]
      } else if names[index] == "BUNDLE25" {
        excludes = ["CLEAROUT30"]
      } else if names[index] == "CANYON20" || names[index] == "ALPINE18" {
        excludes = ["CLEAROUT30"]
      }
      return Promotion(
        id: names[index],
        categories: categories,
        minimumSubtotalCents: minimums[index],
        discountBasisPoints: discounts[index],
        excludes: excludes
      )
    }
  }

  // MARK: - Service payloads

  /// The inventory reading for one product.
  ///
  /// A pure function of the product identifier and a generation counter, so
  /// the inventory burst can publish a *different* reading for the same
  /// product without the fixture becoming stateful.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - generation: Which reading; zero is the first one a session sees.
  ///   - profile: Supplies the variant count the reading covers.
  /// - Returns: A deterministic reading.
  public static func inventory(
    for id: ProductID,
    generation: Int,
    profile: StorefrontProfile
  ) -> InventoryReading {
    var generator = Generator(seed: seed &+ UInt64(bitPattern: Int64(id.raw &* 31 &+ generation)))
    let units = (0..<profile.variantCount).map { _ in generator.next(in: 0...18) }
    return InventoryReading(unitsByVariant: units, restockable: generator.next(upTo: 4) != 0)
  }

  /// The personalized offer for one product.
  ///
  /// Two thirds of products get no offer at all, which is what makes the
  /// offer-shaped invalidation wave narrow enough to be interesting.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - shopper: Whose offer; the tier scales it.
  /// - Returns: A deterministic offer, often ``PersonalizedOffer/none``.
  public static func offer(for id: ProductID, shopper: Shopper) -> PersonalizedOffer {
    var generator = Generator(seed: seed &+ 0xA5 &+ UInt64(id.raw))
    guard generator.next(upTo: 3) == 0 else { return .none }
    let base = generator.next(in: 300...1_800)
    let scaled = base + shopper.tier.rawValue * 150
    return PersonalizedOffer(discountBasisPoints: scaled, reason: "For \(shopper.name)")
  }

  /// The detail payload for one product.
  ///
  /// - Parameter product: The product to describe.
  /// - Returns: A deterministic detail payload.
  public static func detail(for product: Product) -> ProductDetail {
    var generator = Generator(seed: seed &+ 0xD7 &+ UInt64(product.id.raw))
    return ProductDetail(
      summary: "\(product.name) — field-tested, seam-sealed, and built for long days.",
      reviewCount: generator.next(in: 0...2_400),
      averageRatingHundredths: generator.next(in: 320...500)
    )
  }

  /// The shipping quote for a cart.
  ///
  /// A pure function of the inputs a real quote would depend on, so a quote
  /// that arrives for a superseded cart is detectably stale rather than
  /// coincidentally equal.
  ///
  /// - Parameters:
  ///   - subtotalCents: The discounted subtotal being shipped.
  ///   - address: Where it goes.
  ///   - method: How fast.
  ///   - lineCount: How many distinct products are in the box.
  /// - Returns: A deterministic quote.
  public static func shippingQuote(
    subtotalCents: Int,
    address: ShippingAddress,
    method: ShippingMethod,
    lineCount: Int
  ) -> ShippingQuote {
    let base: Int
    let days: Int
    switch method {
    case .standard:
      base = 599
      days = 5
    case .express:
      base = 1_299
      days = 2
    case .overnight:
      base = 2_499
      days = 1
    }
    let marketSurcharge = address.market * 137
    let handling = lineCount * 45
    // Free standard shipping over a threshold, which is what makes a coupon
    // that crosses that threshold change shipping as well as discount.
    let waived = method == .standard && subtotalCents >= 15_000
    return ShippingQuote(
      costCents: waived ? 0 : base + marketSurcharge + handling,
      estimatedDays: days + address.market / 2
    )
  }

  /// The tax quote for a discounted subtotal.
  ///
  /// - Parameters:
  ///   - discountedSubtotalCents: The amount being taxed.
  ///   - address: Which market's rate applies.
  /// - Returns: A deterministic quote.
  public static func taxQuote(
    discountedSubtotalCents: Int,
    address: ShippingAddress
  ) -> TaxQuote {
    let rates = [0, 725, 890, 1_025]
    let rate = rates[address.market % rates.count]
    return TaxQuote(
      taxCents: StorefrontMoney.scaled(discountedSubtotalCents, byBasisPoints: rate),
      rateBasisPoints: rate
    )
  }
}
