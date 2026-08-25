/// The shared vocabulary both drivers speak.
///
/// The headless benchmark and the SwiftUI UI test perform the *same* session,
/// which is only true if both take the query, the cart, and the scroll plan
/// from one place. Everything here is `nonisolated` and pure so the compute-only
/// control can use it too.
public nonisolated enum StorefrontSession {
  /// What the shopper types, one character per domain operation.
  ///
  /// Chosen so that every intermediate prefix matches something: the fixture
  /// vocabulary puts `trail` first among the qualifiers and `shoes` first among
  /// the nouns, so "t", "tr", … each produce a different non-empty candidate
  /// set rather than nine empty ones followed by an answer.
  public static let searchTarget = "trail shoes"

  /// Every prefix of ``searchTarget``, shortest first, excluding the empty one.
  ///
  /// One domain operation per element; a prefix that normalizes to the same
  /// string as its predecessor still costs a turn but starts no new request,
  /// which is the equality gate the search phase is there to exercise.
  public static var searchPrefixes: [String] {
    (1...searchTarget.count).map { String(searchTarget.prefix($0)) }
  }

  /// The distinct normalized queries ``searchPrefixes`` produces.
  ///
  /// The analytically derived expectation for how many suggestion generations
  /// the search phase starts — derived from the query and the normalizer, never
  /// copied from a run.
  public static var distinctNormalizedQueries: [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for prefix in searchPrefixes {
      let normalized = StorefrontKernels.normalize(prefix)
      guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
      result.append(normalized)
    }
    return result
  }

  /// The products the session puts in the cart.
  ///
  /// Spread evenly across the catalog so they land in different categories,
  /// which is what makes the promotion optimizer a decision rather than a sum.
  ///
  /// - Parameters:
  ///   - profile: Supplies how many to choose.
  ///   - catalog: The catalog to choose from.
  /// - Returns: Product identifiers, in the order they are added.
  public static func cartProductIDs(
    for profile: StorefrontProfile,
    catalog: CatalogSnapshot
  ) -> [ProductID] {
    guard !catalog.products.isEmpty else { return [] }
    let stride = max(1, catalog.products.count / (profile.cartProductCount + 1))
    return (1...profile.cartProductCount).map { index in
      ProductID(min(catalog.products.count - 1, index * stride))
    }
  }

  /// Describes one persistent steady-state interaction.
  ///
  /// The global iteration, rather than a sample-local index, determines every
  /// value. That keeps successive benchmark samples from replaying a fixed
  /// product-to-quantity mapping that becomes an equality-gated no-op once the
  /// retained graph has seen its first sample.
  ///
  /// - Parameters:
  ///   - iteration: Monotonic ordinal across warmups and reported samples.
  ///   - products: Products the settled viewport may touch.
  ///   - variantCount: Variants available on each fixture product.
  /// - Returns: The interaction, or `nil` for an empty product set.
  public static func steadyInteraction(
    at iteration: Int,
    products: [ProductID],
    variantCount: Int
  ) -> StorefrontSteadyInteraction? {
    guard !products.isEmpty else { return nil }
    let lap = iteration / products.count
    return StorefrontSteadyInteraction(
      productID: products[iteration % products.count],
      quantity: (lap % 2) + 1,
      variantIndex: (lap + 1) % max(1, variantCount),
      viewRank: iteration + 1
    )
  }

  /// The row windows the scroll phase visits, in order.
  ///
  /// Down through the list a viewport at a time until
  /// ``StorefrontProfile/visitedRowCount`` distinct rows have been seen, then
  /// partly back up. Returning is not decoration: scrolling back re-visits rows
  /// whose state already exists, which is a completely different cost from
  /// visiting a row for the first time, and a benchmark that only ever scrolled
  /// down would never measure it.
  ///
  /// - Parameter profile: Supplies the viewport size and the visit target.
  /// - Returns: The windows to apply, in order.
  public static func scrollPlan(for profile: StorefrontProfile) -> [RowWindow] {
    let step = max(1, profile.viewportRowCount / 2)
    var windows: [RowWindow] = []
    var offset = 0
    while offset + profile.viewportRowCount < profile.visitedRowCount {
      offset += step
      windows.append(RowWindow(offset: offset, length: profile.viewportRowCount))
    }
    // Back up by a third of what was covered, which re-materializes rows whose
    // state the downward pass already created.
    let backSteps = max(1, windows.count / 3)
    for _ in 0..<backSteps {
      offset = max(0, offset - step)
      windows.append(RowWindow(offset: offset, length: profile.viewportRowCount))
    }
    return windows
  }

  /// The products the inventory burst touches.
  ///
  /// Half of them are inside the window the burst phase leaves the list on and
  /// half are far outside it, which is what makes "the offscreen half
  /// invalidated nothing on screen" a claim with two sides.
  ///
  /// - Parameters:
  ///   - profile: Supplies how many to touch.
  ///   - visible: The products currently on screen.
  ///   - previouslyVisited: Products the session has already scrolled past. The
  ///     offscreen half is drawn from here rather than from the far end of the
  ///     catalog on purpose: a burst touching products the session never even
  ///     met would be a weaker claim, because it would be trivially true of any
  ///     implementation.
  ///   - demanded: The products whose row state the list currently demands,
  ///     which the offscreen half must avoid.
  /// - Returns: Touched products: the demanded half first, then the undemanded
  ///   half.
  public static func inventoryBurstIDs(
    for profile: StorefrontProfile,
    visible: [ProductID],
    previouslyVisited: [ProductID],
    demanded: [ProductID]
  ) -> [ProductID] {
    let half = profile.inventoryBurstCount / 2
    let onScreen = Array(visible.prefix(half))
    let demandedSet = Set(demanded)
    let offScreen =
      previouslyVisited
      .filter { !demandedSet.contains($0) }
      .prefix(profile.inventoryBurstCount - onScreen.count)
    return onScreen + Array(offScreen)
  }

  /// How the burst splits, so a checkpoint can name each half.
  ///
  /// The split is on the **demanded** set, not the visible one. A product in
  /// the prefetch margin is offscreen to a shopper but demanded by the graph,
  /// and lumping it into the offscreen half would make that half's claim false
  /// for reasons that have nothing to do with Cog.
  ///
  /// - Parameters:
  ///   - burst: What
  ///     ``inventoryBurstIDs(for:visible:previouslyVisited:demanded:)``
  ///     returned.
  ///   - demanded: The products whose row state the list currently demands.
  /// - Returns: The demanded half and the undemanded half.
  public static func splitBurst(
    _ burst: [ProductID],
    demanded: [ProductID]
  ) -> (onScreen: [ProductID], offScreen: [ProductID]) {
    let demandedSet = Set(demanded)
    return (
      burst.filter { demandedSet.contains($0) },
      burst.filter { !demandedSet.contains($0) }
    )
  }
}

/// The four values one steady-state benchmark iteration writes.
///
/// Favorite state is absent because the operation always toggles it. The other
/// three values are explicit so a test can prove their persistent sequence and
/// the benchmark can replay the exact measured operations into its shadow.
public nonisolated struct StorefrontSteadyInteraction: Sendable, Equatable {
  /// Product the iteration touches.
  public let productID: ProductID

  /// Absolute cart quantity to write, always one or two.
  public let quantity: Int

  /// Variant to select.
  public let variantIndex: Int

  /// Monotonic recently-viewed rank.
  public let viewRank: Int

  /// Creates one planned interaction.
  public init(productID: ProductID, quantity: Int, variantIndex: Int, viewRank: Int) {
    self.productID = productID
    self.quantity = quantity
    self.variantIndex = variantIndex
    self.viewRank = viewRank
  }
}

/// One thing the session promised, and what actually happened.
///
/// A value rather than an assertion so the same trace can be driven by a
/// benchmark (which preconditions on `holds`) and by a test (which reports each
/// failure individually). Both stringify, because a checkpoint that could only
/// be compared numerically would have to be rewritten for every new claim.
public nonisolated struct StorefrontCheckpoint: Sendable, Equatable {
  /// Which phase of the trace recorded this.
  public let phase: String

  /// What is being claimed.
  public let name: String

  /// What the profile and event semantics say should have happened.
  public let expected: String

  /// What happened.
  public let actual: String

  /// Whether the claim holds.
  public var holds: Bool { expected == actual }

  /// Creates a checkpoint.
  public init(phase: String, name: String, expected: String, actual: String) {
    self.phase = phase
    self.name = name
    self.expected = expected
    self.actual = actual
  }

  /// A one-line description for a failure message.
  public var failureDescription: String {
    "\(phase)/\(name): expected \(expected), got \(actual)"
  }
}
