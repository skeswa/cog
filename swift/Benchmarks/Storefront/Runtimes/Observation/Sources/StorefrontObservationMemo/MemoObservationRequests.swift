internal import StorefrontWorkload

// The port's asynchronous layer: what it asks for, when, and what it does with
// an answer.
//
// Two halves, and keeping them apart is the whole design.
//
// `refreshDemand()` is a **hand-written list of what the held screens currently
// need**. It is not a traversal of anything: a person wrote out, screen by
// screen, which requests that screen implies, and a person would have to add a
// line to it the day a screen started reading something new. That is the same
// bargain as the invalidation file, and it is what makes this port's sharpest
// number honest — an offscreen product is not on the list, so an invalidation
// that touches only offscreen products starts exactly zero requests without
// anything having to *decide* that it should.
//
// The other half is the epilogue every request task runs on the MainActor:
// compare the attempt this task was launched with against the cell's current
// attempt, publish or discard accordingly, tell the invalidation scheme what
// landed, settle, and fire the completion barrier — on both branches, exactly
// once. A decision to refuse a stale result is exactly as much of a decision as
// a decision to publish one, and the trace's stale-suggestion step is built on
// being able to await precisely that.

/// A `Sendable` stand-in for whatever the request boundary threw.
///
/// `any Error` is not `Sendable`, and a request result crosses from the task
/// that produced it to the MainActor that decides about it. Rather than reach
/// for an unsafe escape, the port carries the description across and rebuilds an
/// error on the other side. Nothing in this workload inspects an error's type —
/// the refresh outcome compares one word — so the description is the whole of
/// what is needed.
struct MemoObservationRequestFailure: Error, Sendable, CustomStringConvertible {
  /// What the request boundary said went wrong.
  let description: String

  /// Captures one thrown error as a value that can cross an isolation boundary.
  ///
  /// - Parameter error: What the request boundary threw.
  init(_ error: any Error) {
    description = "\(error)"
  }
}

extension MemoObservationStorefrontRuntime {
  // MARK: - What the held screens need

  /// Whether this profile's pricing ladder reads the personalized offer.
  ///
  /// Derived from the profile rather than hard-coded, so a profile that
  /// shortens or lengthens its ladder changes what a cart line demands
  /// automatically. A row on screen always demands an offer, because its badges
  /// read one; a cart line demands one only when the ladder reaches that stage.
  var pricingReadsOffers: Bool {
    StorefrontPricing.ladder.prefix(profile.pricingPolicyCount).contains(.personalizedOffer)
  }

  /// The products the held screens are showing right now.
  ///
  /// One statement of "what is on screen", used twice: by the demand pass to
  /// decide what to ask for, and by the lifetime sweep to decide what may be
  /// dropped. Two statements that could drift apart would eventually release a
  /// row somebody was looking at.
  ///
  /// - Returns: Every product a held observer currently reads.
  func currentlyDemandedProductIDs() -> Set<ProductID> {
    var demanded: Set<ProductID> = []
    if holds.contains(.browse) { demanded.formUnion(windowCache().demandedIDs) }
    if holds.contains(.cart) { demanded.formUnion(cartCache().lineIDs) }
    if holds.contains(.detail), let id = model.selectedProduct { demanded.insert(id) }
    return demanded
  }

  /// Starts every request the held screens need and nothing else.
  ///
  /// Runs at the close of every settlement. Idempotent by construction: a
  /// request whose identity is already answered or already in flight is not
  /// asked again, which is what makes "no duplicate inventory work" a property
  /// of the port rather than of the trace's luck.
  func refreshDemand() {
    if holds.contains(.account) { demandAccount() }

    let readsCatalog =
      holds.contains(.browse) || holds.contains(.search) || holds.contains(.cart)
      || holds.contains(.detail) || funnelIsDemanded
    if readsCatalog { demandCatalog() }
    if holds.contains(.browse) || funnelIsDemanded { demandSearchIndex() }
    if holds.contains(.search) { demandSuggestions() }

    let now = clock.now
    if holds.contains(.browse) {
      for id in windowCache().prefetchIDs {
        productLastDemandedAt[id] = now
        demandInventory(for: id)
        demandOffer(for: id)
      }
    }
    if holds.contains(.cart) {
      let cart = cartCache()
      for id in cart.lineIDs {
        productLastDemandedAt[id] = now
        demandInventory(for: id)
        if pricingReadsOffers { demandOffer(for: id) }
      }
      demandQuotes(for: cart)
    }
    if holds.contains(.detail), let id = model.selectedProduct {
      productLastDemandedAt[id] = now
      demandDetail(for: id)
      demandRecommendations()
    }
  }

  // MARK: - One request each

  /// Claims the next attempt at one cell, or refuses because there is nothing
  /// to ask.
  ///
  /// The request-identity check lives here and nowhere else, so every request in
  /// the port is protected by the same three conditions: the identity is
  /// unchanged, nothing has told the cell its uncaptured inputs moved, and the
  /// answer is either already held or already on its way.
  ///
  /// - Parameters:
  ///   - cell: The cell to claim.
  ///   - key: The identity the current sources imply.
  /// - Returns: The attempt to launch with, or `nil` when asking would be
  ///   duplicate work.
  private func beginRequest<Value>(
    _ cell: inout MemoObservationAsyncCell<Value>,
    key: StorefrontRequestID
  ) -> Int? {
    guard !cell.isSatisfied(by: key) else { return nil }
    cell.needsRefetch = false
    cell.generation += 1
    cell.pendingKey = key
    return cell.generation
  }

  /// Asks for the catalog, once per session unless something re-demands it.
  private func demandCatalog() {
    guard let attempt = beginRequest(&catalogCell, key: .catalog) else { return }
    let service = service
    service.schedule(.catalog)
    launch(
      work: { try await service.catalog() },
      finish: { [self] result in finishCatalog(attempt: attempt, result: result) }
    )
  }

  /// Asks for the signed-in shopper's account.
  private func demandAccount() {
    guard let attempt = beginRequest(&accountCell, key: .account) else { return }
    let service = service
    service.schedule(.account)
    launch(
      work: { try await service.account() },
      finish: { [self] result in finishAccount(attempt: attempt, result: result) }
    )
  }

  /// Asks for the inverted index over the accepted catalog.
  ///
  /// Demanded before the first catalog has landed, deliberately: something asks
  /// which products match the empty query, so the index is requested over an
  /// empty catalog and asked for again when a real one arrives. That is lazy
  /// demand behaving correctly rather than a defect, and both generations are
  /// real requests the driver resolves by name.
  private func demandSearchIndex() {
    guard let attempt = beginRequest(&searchIndexCell, key: .searchIndex) else { return }
    let service = service
    let products = catalogIndexCache().products
    service.schedule(.searchIndex)
    launch(
      work: { try await service.searchIndex(products: products) },
      finish: { [self] result in finishSearchIndex(attempt: attempt, result: result) }
    )
  }

  /// Asks for suggestions for the query as it is normalized right now.
  ///
  /// Keyed on the normalized query, so two keystrokes that normalize the same
  /// way do not start two generations.
  private func demandSuggestions() {
    let query = searchPipelineCache().normalizedQuery
    guard !query.isEmpty else {
      if resign(&suggestionsCell, to: []) { didAcceptSuggestions() }
      return
    }
    let key = StorefrontRequestID.suggestions(query: query)
    guard let attempt = beginRequest(&suggestionsCell, key: key) else { return }
    let service = service
    let products = catalogIndexCache().products
    service.schedule(key)
    launch(
      work: { try await service.suggestions(query: query, products: products) },
      finish: { [self] result in finishSuggestions(key: key, attempt: attempt, result: result) }
    )
  }

  /// Asks for personalized recommendations, if there is a shopper to
  /// recommend for.
  func demandRecommendations() {
    guard let shopper = model.signedInShopper else {
      if resign(&recommendationsCell, to: []) { didAcceptRecommendations() }
      return
    }
    let key = StorefrontRequestID.recommendations(accountID: shopper.accountID)
    guard let attempt = beginRequest(&recommendationsCell, key: key) else { return }
    let service = service
    let products = catalogIndexCache().products
    service.schedule(key)
    launch(
      work: { try await service.recommendations(products: products, shopper: shopper) },
      finish: { [self] result in
        finishRecommendations(key: key, attempt: attempt, result: result)
      }
    )
  }

  /// Asks for one product's live inventory at its current generation.
  ///
  /// - Parameter id: Which product.
  private func demandInventory(for id: ProductID) {
    let generation = model.inventoryGenerations[id] ?? 0
    let key = StorefrontRequestID.inventory(id: id, generation: generation)
    var cell = inventoryCells[id] ?? MemoObservationAsyncCell(value: .unknown)
    let attempt = beginRequest(&cell, key: key)
    inventoryCells[id] = cell
    guard let attempt else { return }
    let service = service
    service.schedule(key)
    launch(
      work: { try await service.inventory(for: id, generation: generation) },
      finish: { [self] result in
        finishInventory(for: id, key: key, attempt: attempt, result: result)
      }
    )
  }

  /// Asks for one product's personalized offer, if there is a shopper.
  ///
  /// - Parameter id: Which product.
  private func demandOffer(for id: ProductID) {
    guard let shopper = model.signedInShopper else {
      if resign(&offerCells, for: id, to: .none) {
        didChangeProduct(id, pricingAffected: true)
      }
      return
    }
    let key = StorefrontRequestID.offer(id: id)
    var cell = offerCells[id] ?? MemoObservationAsyncCell(value: .none)
    let attempt = beginRequest(&cell, key: key)
    offerCells[id] = cell
    guard let attempt else { return }
    let service = service
    service.schedule(key)
    launch(
      work: { try await service.offer(for: id, shopper: shopper) },
      finish: { [self] result in finishOffer(for: id, key: key, attempt: attempt, result: result) }
    )
  }

  /// Asks for one product's detail payload.
  ///
  /// - Parameter id: Which product.
  private func demandDetail(for id: ProductID) {
    guard let product = catalogIndexCache().productIndex[id] else {
      if resign(&detailCells, for: id, to: .empty) { didAcceptDetail(for: id) }
      return
    }
    let key = StorefrontRequestID.detail(id: id)
    var cell = detailCells[id] ?? MemoObservationAsyncCell(value: .empty)
    let attempt = beginRequest(&cell, key: key)
    detailCells[id] = cell
    guard let attempt else { return }
    let service = service
    service.schedule(key)
    launch(
      work: { try await service.detail(for: product) },
      finish: { [self] result in
        finishDetail(for: id, key: key, attempt: attempt, result: result)
      }
    )
  }

  /// Asks for the shipping and tax quotes the settled cart implies.
  ///
  /// An empty cart is not a shipment and nothing in it is taxable, so an empty
  /// cart asks for neither — which is a request a real checkout screen never
  /// sends and a benchmark artifact nobody wants to explain.
  ///
  /// - Parameter cart: The settled cart.
  private func demandQuotes(for cart: MemoObservationCartCache) {
    guard !cart.lineIDs.isEmpty else {
      let shippingChanged = resign(&shippingQuoteCell, to: .pending)
      let taxChanged = resign(&taxQuoteCell, to: .pending)
      if shippingChanged || taxChanged { didAcceptQuote() }
      return
    }
    let address = model.shippingAddress
    let method = model.shippingMethod
    let subtotal = cart.discountedSubtotalCents
    let lineCount = cart.lineIDs.count

    let shippingKey = StorefrontRequestID.shippingQuote(
      subtotalCents: subtotal,
      market: address.market,
      method: method
    )
    if let attempt = beginRequest(&shippingQuoteCell, key: shippingKey) {
      let service = service
      service.schedule(shippingKey)
      launch(
        work: {
          try await service.shippingQuote(
            subtotalCents: subtotal,
            address: address,
            method: method,
            lineCount: lineCount
          )
        },
        finish: { [self] result in
          finishShippingQuote(key: shippingKey, attempt: attempt, result: result)
        }
      )
    }

    let taxKey = StorefrontRequestID.taxQuote(subtotalCents: subtotal, market: address.market)
    if let attempt = beginRequest(&taxQuoteCell, key: taxKey) {
      let service = service
      service.schedule(taxKey)
      launch(
        work: {
          try await service.taxQuote(discountedSubtotalCents: subtotal, address: address)
        },
        finish: { [self] result in
          finishTaxQuote(key: taxKey, attempt: attempt, result: result)
        }
      )
    }
  }

  /// Publishes a resting value for a request the current sources say must not
  /// be made at all.
  ///
  /// The workload's guarded selections — an empty query, a signed-out shopper,
  /// an empty cart, a product outside the catalog — do not merely decline to
  /// ask. They *answer*, with the declaration's resting value, and the
  /// difference is visible to a shopper: clearing the search field empties the
  /// suggestion list rather than leaving the suggestions for the query before
  /// last sitting under it.
  ///
  /// Anything in flight is refused on arrival, because a guard that now holds is
  /// exactly the selection having moved on.
  ///
  /// - Parameters:
  ///   - cell: The cell to rest.
  ///   - resting: The declaration's default.
  /// - Returns: Whether the published value actually changed, so the caller can
  ///   run the one invalidation method that names it. The caller runs it rather
  ///   than this helper, so no invalidation happens while the cell is still
  ///   exclusively borrowed.
  private func resign<Value: Equatable>(
    _ cell: inout MemoObservationAsyncCell<Value>,
    to resting: Value
  ) -> Bool {
    if cell.pendingKey != nil { cell.generation += 1 }
    cell.pendingKey = nil
    cell.satisfiedKey = nil
    cell.needsRefetch = false
    guard cell.value != resting else { return false }
    cell.value = resting
    return true
  }

  /// Publishes a resting value for one keyed cell whose guard now holds.
  ///
  /// Does nothing when no cell exists, because a value nothing has ever demanded
  /// has nothing to rest to.
  ///
  /// - Parameters:
  ///   - cells: The keyed store.
  ///   - id: Which product.
  ///   - resting: The declaration's default.
  /// - Returns: Whether the published value actually changed.
  private func resign<Value: Equatable>(
    _ cells: inout [ProductID: MemoObservationAsyncCell<Value>],
    for id: ProductID,
    to resting: Value
  ) -> Bool {
    guard var cell = cells[id] else { return false }
    let changed = resign(&cell, to: resting)
    cells[id] = cell
    return changed
  }

  // MARK: - Launching

  /// Runs one request off the MainActor and returns its decision to it.
  ///
  /// The work runs `@concurrent` because the request boundary's kernels — the
  /// index build above all — are the largest computations in the workload and
  /// doing them on the MainActor would be a defect rather than a measurement.
  /// The decision comes back to the MainActor because a publish-or-discard
  /// decision is a MainActor decision in every runtime this workload compares.
  ///
  /// - Parameters:
  ///   - work: The request to perform.
  ///   - finish: The epilogue to run on the MainActor with whatever it produced.
  private func launch<Value: Sendable>(
    work: @escaping @Sendable () async throws -> Value,
    finish: @escaping @Sendable @MainActor (Result<Value, MemoObservationRequestFailure>) -> Void
  ) {
    Task { @concurrent in
      let result: Result<Value, MemoObservationRequestFailure>
      do {
        result = .success(try await work())
      } catch {
        result = .failure(MemoObservationRequestFailure(error))
      }
      await MainActor.run { finish(result) }
    }
  }

  // MARK: - Epilogues

  /// Fires the barrier a settlement step armed, if one is armed.
  ///
  /// Cleared as it fires, so one armed barrier absorbs exactly one decision. A
  /// second fire on the same barrier traps by design: a step that reported one
  /// result while two landed would be measuring a different workload.
  private func fireCompletionSignal() {
    guard let signal = armedCompletionSignal else { return }
    armedCompletionSignal = nil
    signal.signal()
  }

  /// Decides about one catalog response.
  private func finishCatalog(
    attempt: Int,
    result: Result<CatalogSnapshot, MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard catalogCell.generation == attempt else { return }
    catalogCell.pendingKey = nil
    // A failure marks the identity answered rather than leaving it hungry: an
    // unmarked failure would be re-asked by the very next settlement, and a
    // failing service would become a request loop.
    catalogCell.satisfiedKey = .catalog
    if case .success(let snapshot) = result {
      catalogCell.value = snapshot
      didAcceptCatalog()
    }
    settle()
  }

  /// Decides about one account response.
  ///
  /// The account observer runs here, and the accepted shopper is written
  /// through to the model's own signed-in fact — one writable place for one
  /// writable thing, exactly as the Cog port's mechanism does.
  private func finishAccount(
    attempt: Int,
    result: Result<Shopper, MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard accountCell.generation == attempt else { return }
    accountCell.pendingKey = nil
    accountCell.satisfiedKey = .account
    guard case .success(let shopper) = result else {
      settle()
      return
    }
    accountCell.value = shopper
    if holds.contains(.account) {
      sink.recordAccount()
      signIn(as: shopper)
    }
    settle()
  }

  /// Decides about one search-index response.
  private func finishSearchIndex(
    attempt: Int,
    result: Result<StorefrontKernels.SearchIndex, MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard searchIndexCell.generation == attempt else { return }
    searchIndexCell.pendingKey = nil
    searchIndexCell.satisfiedKey = .searchIndex
    if case .success(let index) = result {
      searchIndexCell.value = index
      didAcceptSearchIndex()
    }
    settle()
  }

  /// Decides about one suggestions response.
  ///
  /// The generation check is what refuses a completed-but-superseded
  /// suggestion. The scripted boundary leaves cancelled requests suspended by
  /// default, so an old generation really does complete, really does reach this
  /// method, and really is thrown away here.
  private func finishSuggestions(
    key: StorefrontRequestID,
    attempt: Int,
    result: Result<[String], MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard suggestionsCell.generation == attempt else { return }
    suggestionsCell.pendingKey = nil
    suggestionsCell.satisfiedKey = key
    if case .success(let suggestions) = result {
      suggestionsCell.value = suggestions
      didAcceptSuggestions()
    }
    settle()
  }

  /// Decides about one recommendations response, and resolves its handle.
  private func finishRecommendations(
    key: StorefrontRequestID,
    attempt: Int,
    result: Result<[ProductID], MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard recommendationsCell.generation == attempt else { return }
    recommendationsCell.pendingKey = nil
    recommendationsCell.satisfiedKey = key
    switch result {
    case .success(let ids):
      recommendationsCell.value = ids
      resolveRecommendationRefresh(with: .success(ids))
      didAcceptRecommendations()
    case .failure(let error):
      resolveRecommendationRefresh(with: .failure(error))
    }
    settle()
  }

  /// Decides about one inventory response.
  private func finishInventory(
    for id: ProductID,
    key: StorefrontRequestID,
    attempt: Int,
    result: Result<InventoryReading, MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    // A missing cell means the lifetime sweep released this row while its
    // request was in flight. The answer is for a value that no longer exists,
    // so it is discarded rather than resurrecting the row.
    guard var cell = inventoryCells[id], cell.generation == attempt else { return }
    cell.pendingKey = nil
    cell.satisfiedKey = key
    if case .success(let reading) = result { cell.value = reading }
    inventoryCells[id] = cell
    if case .success = result { didChangeProduct(id, pricingAffected: true) }
    settle()
  }

  /// Decides about one offer response.
  private func finishOffer(
    for id: ProductID,
    key: StorefrontRequestID,
    attempt: Int,
    result: Result<PersonalizedOffer, MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard var cell = offerCells[id], cell.generation == attempt else { return }
    cell.pendingKey = nil
    cell.satisfiedKey = key
    if case .success(let offer) = result { cell.value = offer }
    offerCells[id] = cell
    if case .success = result { didChangeProduct(id, pricingAffected: true) }
    settle()
  }

  /// Decides about one detail response.
  private func finishDetail(
    for id: ProductID,
    key: StorefrontRequestID,
    attempt: Int,
    result: Result<ProductDetail, MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard var cell = detailCells[id], cell.generation == attempt else { return }
    cell.pendingKey = nil
    cell.satisfiedKey = key
    if case .success(let detail) = result { cell.value = detail }
    detailCells[id] = cell
    if case .success = result { didAcceptDetail(for: id) }
    settle()
  }

  /// Decides about one shipping quote.
  private func finishShippingQuote(
    key: StorefrontRequestID,
    attempt: Int,
    result: Result<ShippingQuote, MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard shippingQuoteCell.generation == attempt else { return }
    shippingQuoteCell.pendingKey = nil
    shippingQuoteCell.satisfiedKey = key
    if case .success(let quote) = result {
      shippingQuoteCell.value = quote
      didAcceptQuote()
    }
    settle()
  }

  /// Decides about one tax quote.
  private func finishTaxQuote(
    key: StorefrontRequestID,
    attempt: Int,
    result: Result<TaxQuote, MemoObservationRequestFailure>
  ) {
    defer { fireCompletionSignal() }
    guard taxQuoteCell.generation == attempt else { return }
    taxQuoteCell.pendingKey = nil
    taxQuoteCell.satisfiedKey = key
    if case .success(let quote) = result {
      taxQuoteCell.value = quote
      didAcceptQuote()
    }
    settle()
  }

  /// Resolves the outstanding recommendation demand's handle, if there is one.
  ///
  /// - Parameter outcome: What that generation produced.
  func resolveRecommendationRefresh(with outcome: StorefrontRefreshOutcome<[ProductID]>) {
    guard let pending = pendingRecommendationRefresh else { return }
    pendingRecommendationRefresh = nil
    pending.resolve(outcome)
  }

  // MARK: - Lifetime

  /// Drops every per-product entry nothing is showing and whose grace elapsed.
  ///
  /// The port's whole lifetime model, and an ordinary one: a time-to-live cache
  /// with an eviction sweep. Two things make it a real release rather than a
  /// convenient one. It consults ``currentlyDemandedProductIDs()``, so a row an
  /// observer is genuinely holding survives its grace and stays; and it drops
  /// the asynchronous cells alongside the derived ones, so re-demanding a
  /// released row asks the service again rather than answering from a value
  /// that quietly stayed behind.
  ///
  /// An unconditional `removeAll()` would make the teardown phase's release
  /// proof vacuous, and is exactly what this must not be.
  func sweepReleasableProducts() {
    let demanded = currentlyDemandedProductIDs()
    let now = clock.now
    var releasable: [ProductID] = []
    for (id, stamp) in productLastDemandedAt where !demanded.contains(id) {
      if stamp + grace <= now { releasable.append(id) }
    }
    for id in releasable {
      productLastDemandedAt.removeValue(forKey: id)
      pricing.removeValue(forKey: id)
      rows.removeValue(forKey: id)
      inventoryCells.removeValue(forKey: id)
      offerCells.removeValue(forKey: id)
      detailCells.removeValue(forKey: id)
    }
  }
}
