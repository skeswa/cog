/// The heavy computation the Storefront workload actually performs.
///
/// Four algorithms, all deterministic, all pure, and none of them a delay
/// loop. That last point is the whole design: a workload that spins to look
/// busy measures the spin, and a workload that does nothing measures the
/// harness. These do real, meaningful work whose cost scales with the profile.
///
/// Nothing here imports Cog. That is what lets ``computeControl(for:)`` run the
/// exact same algorithms over the exact same inputs with no graph at all, so a
/// reader can see how much of the application workload is Cog and how much is
/// arithmetic — without subtracting two noisy measurements to manufacture a
/// number, which is a different and much worse thing.
public nonisolated enum StorefrontKernels {
  // MARK: - Search index

  /// An inverted index over the catalog.
  ///
  /// Postings are sorted product ordinals, which is what makes intersecting
  /// two of them a linear merge rather than a set operation over hashes.
  public struct SearchIndex: Hashable, Sendable {
    /// Token to the sorted ordinals of the products carrying it.
    public let postings: [String: [Int]]

    /// How many products the index covers, used by the shape assertions.
    public let productCount: Int

    /// An index over nothing: what a search read rests on before the first
    /// accepted index.
    public static let empty = SearchIndex(postings: [:], productCount: 0)

    /// Creates an index.
    public init(postings: [String: [Int]], productCount: Int) {
      self.postings = postings
      self.productCount = productCount
    }
  }

  /// Builds an inverted index over the catalog.
  ///
  /// The dominant cost of the async work the graph schedules at its root, and
  /// deliberately so: this is the one piece of the workload big enough that
  /// doing it on the MainActor would be a defect rather than a measurement.
  ///
  /// - Parameter products: Every catalog product.
  /// - Returns: An index whose postings are sorted and deduplicated.
  public static func buildSearchIndex(products: [Product]) -> SearchIndex {
    var postings: [String: [Int]] = [:]
    postings.reserveCapacity(products.count / 4 + 16)
    for product in products {
      for token in product.tokens {
        postings[token, default: []].append(product.id.raw)
      }
      // Model numbers are their own token, so a shopper who knows the number
      // can find exactly one product. This is what makes postings lists of
      // wildly different lengths, which the intersection has to cope with.
      postings[String(product.id.raw), default: []].append(product.id.raw)
    }
    // `Array(postings.keys)` rather than `postings.keys`: the lazy `keys` view
    // is a projection of the dictionary, and mutating a dictionary while
    // iterating its own key view is the classic way to turn an O(n) loop into a
    // copy-on-write O(n²) one. Measured here at no difference on the standard
    // profile — the optimizer evidently sees through it — and written this way
    // anyway, because relying on that is relying on a compiler's mood.
    for key in Array(postings.keys) {
      postings[key]?.sort()
    }
    return SearchIndex(postings: postings, productCount: products.count)
  }

  /// Trims ASCII whitespace and lowercases, without `Foundation`.
  ///
  /// Deliberately not locale-aware. A locale-dependent fold would make the
  /// workload's inputs depend on the device's language settings, which is
  /// exactly the kind of hidden input a benchmark must not have.
  ///
  /// - Parameter query: The raw query text.
  /// - Returns: The normalized query.
  public static func normalize(_ query: String) -> String {
    var characters = Array(query.lowercased())
    while let first = characters.first, first == " " || first == "\n" || first == "\t" {
      characters.removeFirst()
    }
    while let last = characters.last, last == " " || last == "\n" || last == "\t" {
      characters.removeLast()
    }
    return String(characters)
  }

  /// Splits a raw query into normalized tokens.
  ///
  /// Lowercased, split on anything that is not a letter or digit, and empties
  /// dropped. Deliberately not locale-aware: a locale-dependent fold would
  /// make results depend on the device's language settings, which is exactly
  /// the kind of hidden input a benchmark must not have.
  ///
  /// - Parameter query: The raw query text.
  /// - Returns: Tokens in the order they appeared.
  public static func tokenize(_ query: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for character in query.lowercased() {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }

  /// Intersects the postings lists of every token.
  ///
  /// A prefix match on the final token, because a shopper typing "trail sho"
  /// expects to see shoes; that is also what makes every intermediate
  /// keystroke of "trail shoes" produce a different, non-empty candidate set
  /// rather than nine empty ones followed by an answer.
  ///
  /// - Parameters:
  ///   - index: The inverted index to search.
  ///   - tokens: Normalized query tokens; an empty array means "everything".
  ///   - productCount: How many products exist, for the everything case.
  /// - Returns: Candidate ordinals, ascending.
  public static func candidates(
    in index: SearchIndex,
    tokens: [String],
    productCount: Int
  ) -> [Int] {
    guard let first = tokens.first else { return Array(0..<productCount) }

    var result = postings(in: index, for: first, allowPrefix: tokens.count == 1)
    for token in tokens.dropFirst() {
      let isLast = token == tokens[tokens.count - 1]
      let next = postings(in: index, for: token, allowPrefix: isLast)
      result = intersect(result, next)
      if result.isEmpty { break }
    }
    return result
  }

  /// The postings for one token, optionally unioning every token it prefixes.
  ///
  /// - Parameters:
  ///   - index: The index to read.
  ///   - token: The token to look up.
  ///   - allowPrefix: Whether to union every posting whose key starts with
  ///     `token`. Only the last token of a query gets this treatment, because
  ///     that is the one the shopper is still typing.
  /// - Returns: Sorted ordinals.
  static func postings(in index: SearchIndex, for token: String, allowPrefix: Bool) -> [Int] {
    guard allowPrefix else { return index.postings[token] ?? [] }
    var union: Set<Int> = []
    for (key, ordinals) in index.postings where key.hasPrefix(token) {
      union.formUnion(ordinals)
    }
    return union.sorted()
  }

  /// Linear-merge intersection of two ascending ordinal lists.
  static func intersect(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
    var result: [Int] = []
    result.reserveCapacity(min(lhs.count, rhs.count))
    var left = 0
    var right = 0
    while left < lhs.count && right < rhs.count {
      if lhs[left] == rhs[right] {
        result.append(lhs[left])
        left += 1
        right += 1
      } else if lhs[left] < rhs[right] {
        left += 1
      } else {
        right += 1
      }
    }
    return result
  }

  // MARK: - Ranking

  /// Scores one product against a query.
  ///
  /// Two terms, both meaningful. Token relevance rewards a product whose name
  /// carries the query's tokens early, which is what makes "trail shoes" rank
  /// trail shoes above trail bottles. The feature term is a fixed
  /// eight-dimensional dot product against a fixed weighting, which is the
  /// shape a learned ranker has even when the weights are not learned.
  ///
  /// - Parameters:
  ///   - product: The product to score.
  ///   - tokens: Normalized query tokens.
  /// - Returns: A score; larger is better.
  public static func relevanceScore(product: Product, tokens: [String]) -> Int {
    var tokenScore = 0
    for token in tokens {
      for (position, productToken) in product.tokens.enumerated() {
        if productToken == token {
          tokenScore += 1_000 - position * 120
        } else if productToken.hasPrefix(token) {
          tokenScore += 400 - position * 60
        }
      }
    }
    let featureScore = StorefrontFeatureVector.dot(product.features, rankingWeights)
    return tokenScore * 8 + featureScore
  }

  /// The fixed ranking weights the feature term is scored against.
  ///
  /// Written down rather than derived so that a ranking change is a visible
  /// edit to this line, and so the compute-only control scores against exactly
  /// the same numbers the graph does.
  public static let rankingWeights = StorefrontFeatureVector(6, 3, 4, 9, -7, 2, 1, -2)

  /// Orders candidate products for presentation.
  ///
  /// Ties break on identifier in every mode, without exception. A sort whose
  /// result depends on the input order is a sort whose result depends on the
  /// hash seed, and then the "visible identifiers" checkpoint becomes a
  /// coin flip.
  ///
  /// - Parameters:
  ///   - candidates: Ordinals to order.
  ///   - products: The catalog, indexed by ordinal.
  ///   - scores: Relevance score per ordinal, already computed.
  ///   - prices: Effective price per ordinal, in cents.
  ///   - mode: How the shopper asked for it.
  /// - Returns: Ordered product identifiers.
  public static func rank(
    candidates: [Int],
    products: [Product],
    scores: [Int: Int],
    prices: [Int: Int],
    mode: SortMode
  ) -> [ProductID] {
    let ordered = candidates.sorted { lhs, rhs in
      switch mode {
      case .relevance:
        let left = scores[lhs] ?? 0
        let right = scores[rhs] ?? 0
        if left != right { return left > right }
      case .priceAscending:
        let left = prices[lhs] ?? products[lhs].listPriceCents
        let right = prices[rhs] ?? products[rhs].listPriceCents
        if left != right { return left < right }
      case .priceDescending:
        let left = prices[lhs] ?? products[lhs].listPriceCents
        let right = prices[rhs] ?? products[rhs].listPriceCents
        if left != right { return left > right }
      case .newest:
        let left = products[lhs].features.freshness
        let right = products[rhs].features.freshness
        if left != right { return left > right }
      }
      return lhs < rhs
    }
    return ordered.map { ProductID($0) }
  }

  // MARK: - Promotions

  /// Chooses the best compatible set of promotions for a cart.
  ///
  /// A bounded dynamic-programming pass over subsets, which is genuinely a
  /// decision rather than a sum: promotions exclude one another, so the best
  /// set is not the set of individually best promotions. The bound is
  /// ``StorefrontFixtures/maximumPromotions``, and the table is built
  /// incrementally — `compatible[mask]` is derived from
  /// `compatible[mask without its lowest bit]` — so the pass is
  /// `O(2^n)` table writes rather than `O(2^n · n²)` recomputation.
  ///
  /// - Parameters:
  ///   - lines: The cart, already priced.
  ///   - promotions: The promotions to choose between; at most
  ///     ``StorefrontFixtures/maximumPromotions``.
  ///   - categories: The category of each product on a line.
  ///   - couponID: A coupon the shopper typed, which must be in the chosen set
  ///     when it qualifies. This is what makes applying a coupon change the
  ///     *shape* of the answer rather than merely its size.
  /// - Returns: The chosen plan.
  public static func selectPromotions(
    lines: [CartLine],
    promotions: [Promotion],
    categories: [ProductID: CategoryID],
    couponID: String?
  ) -> PromotionPlan {
    precondition(
      promotions.count <= StorefrontFixtures.maximumPromotions,
      "the promotion search is exponential in the promotion count and is bounded at "
        + "\(StorefrontFixtures.maximumPromotions); \(promotions.count) were offered"
    )
    guard !promotions.isEmpty, !lines.isEmpty else { return .none }

    let subtotal = lines.reduce(0) { $0 + $1.extendedCents }

    // Qualifying amount per promotion: the cart-wide subtotal, or the part of
    // it that falls inside the promotion's categories.
    var qualifying: [Int] = []
    qualifying.reserveCapacity(promotions.count)
    for promotion in promotions {
      if promotion.categories.isEmpty {
        qualifying.append(subtotal)
      } else {
        var amount = 0
        for line in lines {
          guard let category = categories[line.productID] else { continue }
          if promotion.categories.contains(category) { amount += line.extendedCents }
        }
        qualifying.append(amount)
      }
    }

    // Value of each promotion on its own, zero when the cart does not qualify.
    var value: [Int] = []
    value.reserveCapacity(promotions.count)
    for (index, promotion) in promotions.enumerated() {
      let qualifies = subtotal >= promotion.minimumSubtotalCents && qualifying[index] > 0
      value.append(
        qualifies
          ? StorefrontMoney.scaled(qualifying[index], byBasisPoints: promotion.discountBasisPoints)
          : 0
      )
    }

    // Exclusion masks, symmetric: if A excludes B then B excludes A, whatever
    // the fixture says, because a one-sided exclusion is a bug that only shows
    // up in one enumeration order.
    let indexByID = Dictionary(
      uniqueKeysWithValues: promotions.enumerated().map { ($0.element.id, $0.offset) }
    )
    var excludeMask = [Int](repeating: 0, count: promotions.count)
    for (index, promotion) in promotions.enumerated() {
      for excludedID in promotion.excludes {
        guard let other = indexByID[excludedID] else { continue }
        excludeMask[index] |= 1 << other
        excludeMask[other] |= 1 << index
      }
    }

    let requiredMask = couponID.flatMap { indexByID[$0] }.map { 1 << $0 } ?? 0
    let subsetCount = 1 << promotions.count

    var compatible = [Bool](repeating: false, count: subsetCount)
    var total = [Int](repeating: 0, count: subsetCount)
    compatible[0] = true

    var bestMask = 0
    var bestValue = requiredMask == 0 ? 0 : Int.min

    for mask in 1..<subsetCount {
      let lowest = mask & -mask
      let index = lowest.trailingZeroBitCount
      let rest = mask ^ lowest
      guard compatible[rest], excludeMask[index] & rest == 0 else { continue }
      compatible[mask] = true
      total[mask] = total[rest] + value[index]
      guard mask & requiredMask == requiredMask else { continue }
      // Ties break on the smaller mask, so the chosen set is a function of the
      // cart rather than of the enumeration order.
      if total[mask] > bestValue {
        bestValue = total[mask]
        bestMask = mask
      }
    }

    guard bestValue > 0 else { return .none }
    let applied = promotions.enumerated()
      .filter { bestMask & (1 << $0.offset) != 0 && value[$0.offset] > 0 }
      .map(\.element.id)
      .sorted()
    return PromotionPlan(appliedIDs: applied, discountCents: bestValue)
  }

  // MARK: - Recommendations

  /// Scores the whole catalog against a shopper's taste vector.
  ///
  /// The second piece of work large enough to belong off the MainActor: it
  /// touches every product, unlike ranking, which touches only the candidates
  /// the index produced.
  ///
  /// - Parameters:
  ///   - products: The whole catalog.
  ///   - taste: The shopper's taste vector.
  ///   - count: How many to return.
  /// - Returns: The best `count` products, best first, ties broken on
  ///   identifier.
  public static func recommend(
    products: [Product],
    taste: StorefrontFeatureVector,
    count: Int
  ) -> [ProductID] {
    guard count > 0 else { return [] }
    var scored: [(score: Int, id: Int)] = []
    scored.reserveCapacity(products.count)
    for product in products {
      scored.append((StorefrontFeatureVector.dot(product.features, taste), product.id.raw))
    }
    scored.sort { lhs, rhs in
      lhs.score != rhs.score ? lhs.score > rhs.score : lhs.id < rhs.id
    }
    return scored.prefix(count).map { ProductID($0.id) }
  }

  /// Builds the suggestion list for a query.
  ///
  /// Suggestions are catalog names that extend the query, deduplicated to the
  /// distinct noun-and-qualifier pairs a shopper would recognize as
  /// suggestions rather than as products.
  ///
  /// - Parameters:
  ///   - query: The raw query the shopper has typed so far.
  ///   - products: The whole catalog.
  ///   - count: How many suggestions to return.
  /// - Returns: Suggestion strings, best first.
  public static func suggestions(
    for query: String,
    products: [Product],
    count: Int
  ) -> [String] {
    let tokens = tokenize(query)
    guard !tokens.isEmpty, count > 0 else { return [] }
    var seen: Set<String> = []
    var scored: [(score: Int, text: String)] = []
    for product in products {
      let phrase = product.tokens.prefix(3).joined(separator: " ")
      guard !seen.contains(phrase) else { continue }
      let score = relevanceScore(product: product, tokens: tokens)
      guard score > 0 else { continue }
      seen.insert(phrase)
      scored.append((score, phrase))
    }
    scored.sort { lhs, rhs in
      lhs.score != rhs.score ? lhs.score > rhs.score : lhs.text < rhs.text
    }
    return scored.prefix(count).map(\.text)
  }

  // MARK: - The compute-only control

  /// What one pass of the compute-only control produced.
  public struct ComputeControlResult: Hashable, Sendable {
    /// Tokens the index holds.
    public let indexedTokens: Int
    /// Candidates the standard query matched.
    public let candidateCount: Int
    /// The discount the promotion optimizer found.
    public let promotionDiscountCents: Int
    /// The first recommended product, or `nil` when the catalog is empty.
    public let topRecommendation: ProductID?
    /// A digest of every semantic output in the pass, including ranked
    /// identifiers and each directly priced cart line.
    public let checksum: Int

    /// Creates a result.
    public init(
      indexedTokens: Int,
      candidateCount: Int,
      promotionDiscountCents: Int,
      topRecommendation: ProductID?,
      checksum: Int
    ) {
      self.indexedTokens = indexedTokens
      self.candidateCount = candidateCount
      self.promotionDiscountCents = promotionDiscountCents
      self.topRecommendation = topRecommendation
      self.checksum = checksum
    }
  }

  /// Runs every kernel over the profile's fixtures with no graph involved.
  ///
  /// This is the control the application workload is reported *beside*, never
  /// subtracted from. Two noisy measurements differenced produce a third,
  /// noisier number that looks authoritative and is not; printing both and
  /// letting a reader see the ratio is honest and just as useful.
  ///
  /// The inputs are identical to the ones the graph-backed workload uses: the
  /// same catalog, the same query, the same shopper, the same promotions, and
  /// the same cart composition rule.
  ///
  /// - Parameters:
  ///   - profile: The size to run.
  ///   - catalog: The catalog to run against, built once by the caller so
  ///     fixture generation stays outside the measured region.
  /// - Returns: What the pass produced.
  public static func computeControl(
    for profile: StorefrontProfile,
    catalog: CatalogSnapshot
  ) -> ComputeControlResult {
    let shopper = StorefrontFixtures.shopper(for: profile)
    let index = buildSearchIndex(products: catalog.products)
    let tokens = tokenize(StorefrontSession.searchTarget)
    let candidateOrdinals = candidates(
      in: index,
      tokens: tokens,
      productCount: catalog.products.count
    )

    var scores: [Int: Int] = [:]
    var prices: [Int: Int] = [:]
    scores.reserveCapacity(candidateOrdinals.count)
    prices.reserveCapacity(candidateOrdinals.count)
    for ordinal in candidateOrdinals {
      let product = catalog.products[ordinal]
      scores[ordinal] = relevanceScore(product: product, tokens: tokens)
      prices[ordinal] = StorefrontPricing.effectivePriceWithoutGraph(
        product: product,
        variantIndex: 0,
        profile: profile,
        shopper: shopper,
        address: StorefrontFixtures.startingAddress,
        inventory: StorefrontFixtures.inventory(for: product.id, generation: 0, profile: profile),
        offer: StorefrontFixtures.offer(for: product.id, shopper: shopper)
      )
    }

    let ranked = rank(
      candidates: candidateOrdinals,
      products: catalog.products,
      scores: scores,
      prices: prices,
      mode: .relevance
    )

    let cartIDs = StorefrontSession.cartProductIDs(for: profile, catalog: catalog)
    let lines = cartIDs.enumerated().map { position, id -> CartLine in
      let product = catalog.products[id.raw]
      let quantity = position + 1
      let inventory = StorefrontFixtures.inventory(
        for: id,
        generation: 0,
        profile: profile
      )
      return CartLine(
        productID: id,
        name: product.name,
        variantIndex: 0,
        quantity: quantity,
        unitPriceCents: StorefrontPricing.effectivePriceWithoutGraph(
          product: product,
          variantIndex: 0,
          profile: profile,
          shopper: shopper,
          address: StorefrontFixtures.startingAddress,
          inventory: inventory,
          offer: StorefrontFixtures.offer(for: id, shopper: shopper),
          coupon: StorefrontFixtures.sessionCoupon,
          cartQuantity: quantity
        ),
        inStock: inventory.units(forVariant: 0) >= quantity
      )
    }
    let categories = Dictionary(
      uniqueKeysWithValues: catalog.products.map { ($0.id, $0.category) }
    )
    let plan = selectPromotions(
      lines: lines,
      promotions: StorefrontFixtures.promotions(for: profile),
      categories: categories,
      couponID: StorefrontFixtures.sessionCoupon.raw
    )

    let recommended = recommend(
      products: catalog.products,
      taste: shopper.taste,
      count: profile.recommendationCount
    )

    var checksum = 0
    checksum = mix(checksum, index.postings.count)
    checksum = mix(checksum, candidateOrdinals.count)
    for id in ranked.prefix(profile.viewportRowCount) { checksum = mix(checksum, id.raw) }
    for line in lines {
      checksum = mix(checksum, line.productID.raw)
      checksum = mix(checksum, line.quantity)
      checksum = mix(checksum, line.unitPriceCents)
      checksum = mix(checksum, line.inStock ? 1 : 0)
    }
    checksum = mix(checksum, plan.discountCents)
    for id in recommended { checksum = mix(checksum, id.raw) }

    return ComputeControlResult(
      indexedTokens: index.postings.count,
      candidateCount: candidateOrdinals.count,
      promotionDiscountCents: plan.discountCents,
      topRecommendation: recommended.first,
      checksum: checksum
    )
  }

  /// Folds one value into a running checksum.
  ///
  /// An order-sensitive mix on purpose: two screens showing the same products
  /// in a different order are a defect, and a commutative digest could not
  /// tell them apart.
  ///
  /// - Parameters:
  ///   - accumulator: The running value.
  ///   - value: The value to fold in.
  /// - Returns: The new running value.
  public static func mix(_ accumulator: Int, _ value: Int) -> Int {
    var hash = UInt64(bitPattern: Int64(accumulator))
    hash = (hash ^ UInt64(bitPattern: Int64(value))) &* 0x100_0000_01B3
    hash ^= hash >> 29
    return Int(truncatingIfNeeded: Int64(bitPattern: hash))
  }
}
