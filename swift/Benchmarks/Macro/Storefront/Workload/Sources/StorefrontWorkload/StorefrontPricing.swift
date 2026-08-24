/// The pricing pipeline: a ladder of real policies, applied in a fixed order.
///
/// Sixteen stages, and not one of them is an identity node or a `+ 1`. Each
/// stage is a policy a real storefront has — a regional book, a membership
/// tier, a campaign, a coupon, a quantity break, a markdown, a clearance rule,
/// a loyalty burn, a variant premium, a levy, a shipping subsidy, a competitor
/// match, a retargeting nudge, a personalized offer, a floor, and a charm
/// rounding — and each reads a **different** part of the graph. That last
/// point is what makes the pipeline worth measuring: changing the coupon
/// invalidates the coupon stage and everything below it and nothing above it,
/// which is precisely the behavior a fine-grained graph exists to provide and
/// a pipeline of identity nodes could never demonstrate.
///
/// Every function here is pure arithmetic over integer cents. The graph side
/// lives in ``StorefrontState``, which reads the inputs each policy needs and
/// calls the matching function; the compute-only control calls the same
/// functions in the same order with no graph at all.
public nonisolated enum StorefrontPricing {
  /// One policy in the ladder.
  ///
  /// The raw values are stable because a stage key carries a policy index and
  /// a checkpoint's expectations are computed from that index.
  public enum Policy: Int, Hashable, Sendable, CaseIterable {
    /// Applies the shipping market's price book multiplier.
    case regionalMarket = 0
    /// Applies the signed-in shopper's membership discount.
    case membershipTier
    /// Applies the campaign running in the product's category.
    case categoryCampaign
    /// Applies a typed coupon when it covers this product.
    case couponCode
    /// Applies a quantity break for what is already in the cart.
    case bundleQuantity
    /// Marks down a product live inventory says is deep.
    case inventoryMarkdown
    /// Clears out a product the warehouse will not restock.
    case clearance
    /// Burns loyalty points against the price.
    case loyaltyBurn
    /// Adds the selected variant's premium, or removes its discount.
    case variantPremium
    /// Adds the category's environmental levy.
    case ecoLevy
    /// Subsidizes the price when an expensive shipping method was chosen.
    case shippingSubsidy
    /// Matches a competitor's deterministic price when it is lower.
    case competitorMatch
    /// Nudges a product the shopper looked at earlier in this session.
    case recentlyViewedNudge
    /// Applies the personalized offer the offer service returned.
    case personalizedOffer
    /// Refuses to go below the wholesale floor.
    case priceFloor
    /// Rounds to a charm price.
    case charmRounding
  }

  /// The ladder, in application order.
  ///
  /// A profile with fewer policies takes a **prefix** of this array, so a
  /// smaller profile is a shorter real ladder rather than the same ladder with
  /// stages stubbed out.
  public static let ladder: [Policy] = Policy.allCases

  // MARK: - Stage identity

  /// Which price the pipeline starts from.
  public enum PriceBook: Int, Hashable, Sendable, CaseIterable {
    /// The list price, plus the selected variant's delta.
    case retail = 0
    /// A member-only base, available from ``MembershipTier/member`` upward.
    case member
    /// A wholesale base, available at ``MembershipTier/plus`` only.
    case wholesale

    /// Whether a shopper of `tier` may be offered this book.
    ///
    /// - Parameter tier: The shopper's membership tier.
    /// - Returns: Whether the book qualifies.
    public func qualifies(for tier: MembershipTier) -> Bool {
      switch self {
      case .retail: true
      case .member: tier >= .member
      case .wholesale: tier >= .plus
      }
    }
  }

  /// The key of one node of the pricing pipeline.
  ///
  /// A product, a price book, and how many policies have been applied. Stage
  /// zero is the book's base price; stage `n` is the price after
  /// `ladder[n - 1]`. Keyed rather than declared sixteen times over because
  /// sixteen near-identical declarations would be sixteen places to make the
  /// same mistake, and because a keyed recursive pipeline is what a real app
  /// with per-entity pricing actually writes.
  public struct StageKey: Hashable, Sendable, CustomStringConvertible {
    /// The product being priced.
    public let productID: ProductID

    /// Which book this ladder starts from.
    public let book: PriceBook

    /// How many policies have been applied, `0...ladder.count`.
    public let stage: Int

    /// Creates a key.
    public init(productID: ProductID, book: PriceBook, stage: Int) {
      self.productID = productID
      self.book = book
      self.stage = stage
    }

    /// The key one stage earlier.
    ///
    /// - Returns: The previous stage, or `nil` at the base.
    public var previous: StageKey? {
      guard stage > 0 else { return nil }
      return StageKey(productID: productID, book: book, stage: stage - 1)
    }

    /// The policy this stage applies, or `nil` at the base.
    public var policy: Policy? {
      guard stage > 0, stage <= ladder.count else { return nil }
      return ladder[stage - 1]
    }

    public var description: String { "\(productID)/\(book)/\(stage)" }
  }

  // MARK: - Base prices

  /// The price a book starts from, before any policy.
  ///
  /// - Parameters:
  ///   - product: The product being priced.
  ///   - book: Which book.
  ///   - variantIndex: The selected variant, whose stock and identity the
  ///     member book keys off.
  /// - Returns: The base price in cents.
  public static func basePrice(
    product: Product,
    book: PriceBook,
    variantIndex: Int
  ) -> Int {
    switch book {
    case .retail:
      return product.listPriceCents
    case .member:
      return StorefrontMoney.scaled(product.listPriceCents, byBasisPoints: 9_100)
    case .wholesale:
      return max(product.wholesaleBaseCents, 100 + variantIndex)
    }
  }

  // MARK: - The policies

  /// Applies the shipping market's price book multiplier.
  public static func regionalMarket(_ cents: Int, market: Int) -> Int {
    let multipliers = [10_000, 10_250, 9_850, 10_600]
    return StorefrontMoney.scaled(cents, byBasisPoints: multipliers[market % multipliers.count])
  }

  /// Applies the signed-in shopper's membership discount.
  public static func membershipTier(_ cents: Int, tier: MembershipTier) -> Int {
    switch tier {
    case .guest: cents
    case .member: StorefrontMoney.scaled(cents, byBasisPoints: 9_700)
    case .plus: StorefrontMoney.scaled(cents, byBasisPoints: 9_400)
    }
  }

  /// Applies the campaign running in a category.
  ///
  /// Campaigns are a deterministic function of the category ordinal, so a
  /// category filter change moves a whole band of prices at once — which is
  /// the invalidation wave the sectioned list is there to show.
  public static func categoryCampaign(_ cents: Int, category: CategoryID) -> Int {
    let basisPoints = [10_000, 9_600, 10_000, 9_200, 10_000, 9_800][category.raw % 6]
    return StorefrontMoney.scaled(cents, byBasisPoints: basisPoints)
  }

  /// Applies a typed coupon when it covers this product's category.
  ///
  /// - Parameters:
  ///   - cents: The running price.
  ///   - coupon: What the shopper typed, or `nil`.
  ///   - category: The product's category.
  ///   - promotions: The promotion catalog the coupon is looked up in.
  /// - Returns: The price after the coupon, or unchanged when it does not
  ///   apply.
  public static func couponCode(
    _ cents: Int,
    coupon: CouponCode?,
    category: CategoryID,
    promotions: [Promotion]
  ) -> Int {
    guard let coupon else { return cents }
    guard let promotion = promotions.first(where: { $0.id == coupon.raw }) else { return cents }
    guard promotion.categories.isEmpty || promotion.categories.contains(category) else {
      return cents
    }
    return StorefrontMoney.scaled(cents, byBasisPoints: 10_000 - promotion.discountBasisPoints)
  }

  /// Applies a quantity break for what is already in the cart.
  public static func bundleQuantity(_ cents: Int, cartQuantity: Int) -> Int {
    switch cartQuantity {
    case 0, 1: cents
    case 2, 3: StorefrontMoney.scaled(cents, byBasisPoints: 9_750)
    default: StorefrontMoney.scaled(cents, byBasisPoints: 9_300)
    }
  }

  /// Marks down a product live inventory says is deep.
  public static func inventoryMarkdown(_ cents: Int, availableUnits: Int) -> Int {
    guard availableUnits >= 14 else { return cents }
    return StorefrontMoney.scaled(cents, byBasisPoints: 9_500)
  }

  /// Clears out a product the warehouse will not restock.
  public static func clearance(_ cents: Int, restockable: Bool, availableUnits: Int) -> Int {
    guard !restockable, availableUnits > 0 else { return cents }
    return StorefrontMoney.scaled(cents, byBasisPoints: 8_500)
  }

  /// Burns loyalty points against the price.
  ///
  /// Capped at a tenth of the running price, so a large balance cannot drive a
  /// price to zero and hide every policy below it.
  public static func loyaltyBurn(_ cents: Int, loyaltyPoints: Int) -> Int {
    let burn = min(loyaltyPoints / 100, cents / 10)
    return cents - burn
  }

  /// Adds the selected variant's premium, or removes its discount.
  public static func variantPremium(_ cents: Int, delta: Int) -> Int {
    max(0, cents + delta)
  }

  /// Adds the category's environmental levy.
  public static func ecoLevy(_ cents: Int, category: CategoryID) -> Int {
    cents + [0, 35, 0, 75, 15, 0][category.raw % 6]
  }

  /// Subsidizes the price when an expensive shipping method was chosen.
  public static func shippingSubsidy(_ cents: Int, method: ShippingMethod) -> Int {
    switch method {
    case .standard: cents
    case .express: max(0, cents - 100)
    case .overnight: max(0, cents - 250)
    }
  }

  /// Matches a competitor's deterministic price when it is lower.
  public static func competitorMatch(_ cents: Int, product: Product) -> Int {
    let competitor = StorefrontMoney.scaled(
      product.listPriceCents,
      byBasisPoints: 8_900 + (product.id.raw % 17) * 80
    )
    return min(cents, max(competitor, product.wholesaleBaseCents))
  }

  /// Nudges a product the shopper looked at earlier in this session.
  public static func recentlyViewedNudge(_ cents: Int, viewRank: Int) -> Int {
    guard viewRank > 0 else { return cents }
    return StorefrontMoney.scaled(cents, byBasisPoints: 9_900)
  }

  /// Applies the personalized offer the offer service returned.
  public static func personalizedOffer(_ cents: Int, offer: PersonalizedOffer) -> Int {
    guard offer.discountBasisPoints > 0 else { return cents }
    return StorefrontMoney.scaled(cents, byBasisPoints: 10_000 - offer.discountBasisPoints)
  }

  /// Refuses to go below the wholesale floor.
  public static func priceFloor(_ cents: Int, product: Product) -> Int {
    max(cents, StorefrontMoney.scaled(product.wholesaleBaseCents, byBasisPoints: 10_500))
  }

  /// Rounds to a charm price.
  ///
  /// Ninety-five cents below fifty dollars, ninety-nine above, which is a real
  /// merchandising rule and, usefully, one that makes many nearby inputs
  /// collapse to the same output — so an equality-gated declaration on top of
  /// it genuinely stops invalidation waves.
  public static func charmRounding(_ cents: Int) -> Int {
    guard cents > 0 else { return 0 }
    let ending = cents < 5_000 ? 95 : 99
    let whole = cents / 100
    let candidate = whole * 100 + ending
    return candidate <= cents ? candidate : max(ending, (whole - 1) * 100 + ending)
  }

  // MARK: - The graph-free ladder

  /// Runs the whole ladder with no graph, for the compute-only control and for
  /// the correctness tests that check the graph agrees with the arithmetic.
  ///
  /// The stage order, the policy prefix, and every input are identical to what
  /// ``StorefrontState`` reads. If these two ever disagree, the correctness
  /// suite fails before any number is reported, which is the point of having
  /// both.
  ///
  /// - Parameters:
  ///   - product: The product to price.
  ///   - variantIndex: The selected variant.
  ///   - profile: Supplies the policy prefix and price book count.
  ///   - shopper: The signed-in shopper.
  ///   - address: The shipping address, which decides the market.
  ///   - inventory: The accepted live inventory reading.
  ///   - offer: The accepted personalized offer.
  ///   - coupon: A typed coupon, or `nil`.
  ///   - cartQuantity: How many are already in the cart.
  ///   - viewRank: How recently the shopper viewed this product.
  ///   - method: The chosen shipping method.
  /// - Returns: The effective price in cents.
  public static func effectivePriceWithoutGraph(
    product: Product,
    variantIndex: Int,
    profile: StorefrontProfile,
    shopper: Shopper,
    address: ShippingAddress,
    inventory: InventoryReading,
    offer: PersonalizedOffer,
    coupon: CouponCode? = nil,
    cartQuantity: Int = 0,
    viewRank: Int = 0,
    method: ShippingMethod = .standard
  ) -> Int {
    let promotions = StorefrontFixtures.promotions(for: profile)
    let books = PriceBook.allCases.prefix(profile.priceBookCount)
      .filter { $0.qualifies(for: shopper.tier) }
    let policies = ladder.prefix(profile.pricingPolicyCount)
    let variantDelta =
      variantIndex < product.variants.count ? product.variants[variantIndex].priceDeltaCents : 0
    let availableUnits = inventory.units(forVariant: variantIndex)

    var best: Int?
    for book in books {
      var cents = basePrice(product: product, book: book, variantIndex: variantIndex)
      for policy in policies {
        switch policy {
        case .regionalMarket: cents = regionalMarket(cents, market: address.market)
        case .membershipTier: cents = membershipTier(cents, tier: shopper.tier)
        case .categoryCampaign: cents = categoryCampaign(cents, category: product.category)
        case .couponCode:
          cents = couponCode(
            cents,
            coupon: coupon,
            category: product.category,
            promotions: promotions
          )
        case .bundleQuantity: cents = bundleQuantity(cents, cartQuantity: cartQuantity)
        case .inventoryMarkdown: cents = inventoryMarkdown(cents, availableUnits: availableUnits)
        case .clearance:
          cents = clearance(
            cents,
            restockable: inventory.restockable,
            availableUnits: availableUnits
          )
        case .loyaltyBurn: cents = loyaltyBurn(cents, loyaltyPoints: shopper.loyaltyPoints)
        case .variantPremium: cents = variantPremium(cents, delta: variantDelta)
        case .ecoLevy: cents = ecoLevy(cents, category: product.category)
        case .shippingSubsidy: cents = shippingSubsidy(cents, method: method)
        case .competitorMatch: cents = competitorMatch(cents, product: product)
        case .recentlyViewedNudge: cents = recentlyViewedNudge(cents, viewRank: viewRank)
        case .personalizedOffer: cents = personalizedOffer(cents, offer: offer)
        case .priceFloor: cents = priceFloor(cents, product: product)
        case .charmRounding: cents = charmRounding(cents)
        }
      }
      best = best.map { min($0, cents) } ?? cents
    }
    return best ?? product.listPriceCents
  }
}
