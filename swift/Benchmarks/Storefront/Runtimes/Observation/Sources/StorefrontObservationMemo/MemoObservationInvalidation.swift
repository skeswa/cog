internal import StorefrontWorkload

// The whole invalidation scheme, in one file, so it can be read and counted.
//
// This is the file the comparison is really about. Everything a fine-grained
// graph derives from declared dependencies, a hand-written port writes out: one
// method per source, each naming, by name, every cache that source's value
// reaches and every observer that owes a run afterwards. There is no mechanism
// here. Nothing walks an edge list, nothing compares a version stamp, nothing
// records what a computation read. A human decided each of these lines, and a
// human would have to revisit them every time a policy, a badge, or a screen
// changed.
//
// The interesting failure mode of code like this is not that it is slow. It is
// that it is *quietly wrong*: a new pricing policy that reads the shipping
// address, added six months later by someone who did not know
// `didWriteShippingAddress()` existed, produces a screen that shows a stale
// price until something unrelated happens to clear the cache. Nothing in this
// file can catch that. The port's `README.md` records the line count below for
// exactly this reason, it is the maintenance surface the numbers are bought
// with.
//
// Two conventions hold throughout:
//
//   * A method clears caches first and sets dirty flags second, so a reader can
//     see at a glance what became invalid and who has to re-run because of it.
//   * A per-product method consults the demanded set before marking the browse
//     observer dirty. That one condition is what makes an offscreen change free,
//     and it is why the port can declare zero browse runs and zero request
//     starts for an invalidation that touches only offscreen products.

extension MemoObservationStorefrontRuntime {
  // MARK: - Global inputs

  /// The search text changed in a way that changes its normalization.
  ///
  /// The whole funnel is rebuilt: tokens, candidates, per-candidate scores,
  /// eligibility, ranking, and sections. Cog would rebuild the same work for a
  /// query change; the difference is that Cog would *not* rebuild it for a sort
  /// change, and this port will.
  func didWriteSearchQuery() {
    searchPipeline = nil
    window = nil
    browseDirty = true
  }

  /// The category filter changed.
  func didWriteCategory() {
    searchPipeline = nil
    window = nil
    browseDirty = true
  }

  /// The in-stock filter changed.
  func didWriteInStockOnly() {
    searchPipeline = nil
    window = nil
    browseDirty = true
  }

  /// The sort mode changed.
  ///
  /// One of the two places this port is knowingly coarser than the Cog port: a
  /// sort change re-runs the candidate intersection and the relevance scoring
  /// even though neither can have moved. Splitting the funnel into eight cells
  /// to avoid that is the hand-written dependency graph this port must not be.
  func didWriteSortMode() {
    searchPipeline = nil
    window = nil
    browseDirty = true
  }

  /// The materialized row window moved.
  func didWriteRowWindow() {
    window = nil
    browseDirty = true
  }

  /// The open product changed, in either direction.
  func didWriteSelectedProduct() {
    detailDirty = true
  }

  /// The signed-in shopper changed.
  ///
  /// The widest invalidation in the port, and honestly so: the membership tier
  /// and the loyalty balance are both pricing policies, so every product's
  /// ladder is affected, and every personalized offer must be asked for again
  /// because an offer is a fact about a shopper.
  func didWriteShopper() {
    invalidateEveryLadder()
    for id in offerCells.keys { offerCells[id]?.needsRefetch = true }
    recommendationsCell.needsRefetch = true
  }

  /// The coupon changed.
  func didWriteCoupon() {
    invalidateEveryLadder()
  }

  /// The shipping address changed.
  ///
  /// Reaches the ladder through the regional price book, and the quote
  /// identities through the market.
  func didWriteShippingAddress() {
    invalidateEveryLadder()
  }

  /// The shipping method changed.
  ///
  /// Reaches the ladder through the shipping subsidy, and the shipping quote
  /// identity directly.
  func didWriteShippingMethod() {
    invalidateEveryLadder()
  }

  /// The cart's membership or one line's quantity changed.
  ///
  /// - Parameter id: The product whose line moved.
  func didWriteCart(affecting id: ProductID) {
    cart = nil
    cartDirty = true
    // A quantity is a pricing input, the bundle-quantity break reads it, and
    // an in-cart badge is a row input.
    didChangeProduct(id, pricingAffected: true)
  }

  // MARK: - Per-product inputs

  /// One product's inputs changed.
  ///
  /// The demanded check is the honest team's optimization and the reason the
  /// burst phase's central claim is true for this port: a product nothing is
  /// showing has its cached row dropped and stops there. No observer re-runs, no
  /// ladder is recomputed, and, because the demand pass only ever walks what
  /// the held screens want, no request is started for it either.
  ///
  /// - Parameters:
  ///   - id: Which product moved.
  ///   - pricingAffected: Whether one of that product's *pricing* inputs moved,
  ///     as opposed to a row-only input such as the favorite flag.
  func didChangeProduct(_ id: ProductID, pricingAffected: Bool) {
    if pricingAffected { pricing.removeValue(forKey: id) }
    rows.removeValue(forKey: id)
    if model.cartContents.contains(id) {
      cart = nil
      cartDirty = true
    }
    if window?.demandedIDs.contains(id) == true { browseDirty = true }
  }

  /// Every product's ladder is stale, and so is every row and the cart.
  ///
  /// Factored out because four global sources reach every ladder at once and
  /// four copies of the same six lines would be four places to forget one.
  func invalidateEveryLadder() {
    pricing.removeAll(keepingCapacity: true)
    rows.removeAll(keepingCapacity: true)
    cart = nil
    browseDirty = true
    cartDirty = true
  }

  // MARK: - Accepted responses

  /// A catalog response was accepted.
  ///
  /// The root of the browse half of the workload, so nearly everything goes:
  /// the index, the funnel, the window, every ladder, every row, and the cart.
  /// Three requests are keyed on an identity that does not mention the catalog
  ///, the search index, suggestions, and recommendations, so each is told
  /// explicitly that its input moved.
  func didAcceptCatalog() {
    catalogIndex = nil
    searchPipeline = nil
    window = nil
    invalidateEveryLadder()
    searchIndexCell.needsRefetch = true
    suggestionsCell.needsRefetch = true
    recommendationsCell.needsRefetch = true
    for id in detailCells.keys { detailCells[id]?.needsRefetch = true }
  }

  /// A search-index response was accepted.
  func didAcceptSearchIndex() {
    searchPipeline = nil
    window = nil
    browseDirty = true
  }

  /// A suggestions response was accepted.
  func didAcceptSuggestions() {
    searchDirty = true
  }

  /// A recommendations response was accepted.
  func didAcceptRecommendations() {
    if model.selectedProduct != nil { detailDirty = true }
  }

  /// A detail response was accepted.
  ///
  /// - Parameter id: Whose detail landed.
  func didAcceptDetail(for id: ProductID) {
    if model.selectedProduct == id { detailDirty = true }
  }

  /// A shipping or tax quote was accepted.
  ///
  /// Nothing is cleared: the order total and the checkout readiness are
  /// recomputed on every cart render rather than cached, precisely so an
  /// accepted quote does not re-run the promotion optimizer.
  func didAcceptQuote() {
    cartDirty = true
  }
}
