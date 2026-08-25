import StorefrontWorkload

// The raw port's asynchronous layer: what it reads, what it asks for, and how
// it decides whether an answer is still wanted.
//
// Ten asynchronous values, at the four depths the Cog port declares them: the
// catalog and the account at the root, the search index and the recommendations
// mid-graph, inventory and offers per row, a detail payload at the leaf, and the
// shipping and tax quotes downstream of a settled cart. Each has one slot, one
// accepted value on the model, and one record of what it last asked for.
//
// Reads are **total**. A value read returns the last accepted success and rests
// on the same declaration default its Cog counterpart rests on — `.empty`,
// `nil`, `[]`, `.unknown`, `.none`, `.pending` — so a request in flight never
// makes a value unavailable and no loading case ever reaches a screen. Surfacing
// one would change what the browse observer depends on and therefore its run
// counts, which is a different session rather than a different rendering.
//
// The five short-circuit guards are reproduced exactly and schedule nothing: an
// empty normalized query has no suggestions, a signed-out shopper has no
// recommendations and no offers, an empty cart has no quotes, and a product that
// is not in the catalog has no detail payload.
extension RawObservationStorefrontRuntime {
  // MARK: - Value reads

  /// The accepted catalog, demanding it.
  func catalogValue() -> CatalogSnapshot {
    demand(
      .catalog,
      RawObservationAsyncDemand(request: .catalog, refreshEpoch: refreshEpoch(of: .catalog)))
    return model.catalog
  }

  /// The accepted account response, demanding it.
  func accountValue() -> Shopper? {
    demand(
      .account,
      RawObservationAsyncDemand(request: .account, refreshEpoch: refreshEpoch(of: .account)))
    return model.account
  }

  /// The accepted search index, demanding it.
  ///
  /// Its request identity carries nothing, so the accepted-catalog epoch is what
  /// tells the port that the index has to be built again — the whole reason a
  /// slot and a request identity are two different things here. The Cog
  /// declaration expresses the same fact by reading the catalog's products
  /// inside its selector.
  func searchIndexValue() -> StorefrontKernels.SearchIndex {
    demand(
      .searchIndex,
      RawObservationAsyncDemand(
        request: .searchIndex,
        catalogEpoch: catalogEpoch,
        refreshEpoch: refreshEpoch(of: .searchIndex)
      )
    )
    return model.searchIndex
  }

  /// The accepted suggestions for the current query, demanding them.
  ///
  /// Keyed off the *normalized* query, so two keystrokes that normalize the same
  /// way do not start two generations — which is exactly what the search phase
  /// counts.
  func suggestionsValue() -> [String] {
    let normalizedQuery = normalizedQuery()
    guard !normalizedQuery.isEmpty else {
      demandNothing(.suggestions)
      return []
    }
    demand(
      .suggestions,
      RawObservationAsyncDemand(
        request: .suggestions(query: normalizedQuery),
        catalogEpoch: catalogEpoch,
        refreshEpoch: refreshEpoch(of: .suggestions)
      )
    )
    return model.suggestions
  }

  /// The accepted recommendations, demanding them.
  func recommendationsValue() -> [ProductID] {
    guard let shopper = model.signedInShopper else {
      demandNothing(.recommendations)
      return []
    }
    demand(
      .recommendations,
      RawObservationAsyncDemand(
        request: .recommendations(accountID: shopper.accountID),
        catalogEpoch: catalogEpoch,
        shopperEpoch: shopperEpoch,
        refreshEpoch: refreshEpoch(of: .recommendations)
      )
    )
    return model.recommendations
  }

  /// The accepted inventory reading for one product, demanding it.
  ///
  /// The generation is part of the request identity, so an inventory burst that
  /// touches this product asks a different question — but only if something
  /// still reads this product at all.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The reading, or ``InventoryReading/unknown``.
  func inventoryValue(for id: ProductID) -> InventoryReading {
    let generation = model.inventoryGenerations[id] ?? 0
    demand(
      .inventory(id),
      RawObservationAsyncDemand(
        request: .inventory(id: id, generation: generation),
        refreshEpoch: refreshEpoch(of: .inventory(id))
      )
    )
    return model.inventory[id] ?? .unknown
  }

  /// The accepted personalized offer for one product, demanding it.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The offer, or ``PersonalizedOffer/none``.
  func offerValue(for id: ProductID) -> PersonalizedOffer {
    guard model.signedInShopper != nil else {
      demandNothing(.offer(id))
      return .none
    }
    demand(
      .offer(id),
      RawObservationAsyncDemand(
        request: .offer(id: id),
        shopperEpoch: shopperEpoch,
        refreshEpoch: refreshEpoch(of: .offer(id))
      )
    )
    return model.offers[id] ?? .none
  }

  /// The accepted detail payload for one product, demanding it.
  ///
  /// - Parameter id: Which product.
  /// - Returns: The payload, or ``ProductDetail/empty``.
  func detailValue(for id: ProductID) -> ProductDetail {
    guard productIndex()[id] != nil else {
      demandNothing(.detail(id))
      return .empty
    }
    demand(
      .detail(id),
      RawObservationAsyncDemand(
        request: .detail(id: id),
        catalogEpoch: catalogEpoch,
        refreshEpoch: refreshEpoch(of: .detail(id))
      )
    )
    return model.details[id] ?? .empty
  }

  /// The accepted shipping quote, demanding it.
  ///
  /// The deepest asynchronous value in the workload: its request identity is the
  /// discounted subtotal, which is downstream of the promotion plan, which is
  /// downstream of every cart line, which is downstream of every pricing ladder.
  /// This port recomputes that entire chain to answer the question of *which*
  /// quote to ask for, on every render — which is the cost being measured.
  func shippingQuoteValue() -> ShippingQuote {
    let cartLineIDs = cartLineIDs()
    guard !cartLineIDs.isEmpty else {
      demandNothing(.shippingQuote)
      return .pending
    }
    demand(
      .shippingQuote,
      RawObservationAsyncDemand(
        request: .shippingQuote(
          subtotalCents: discountedSubtotal(),
          market: model.shippingAddress.market,
          method: model.shippingMethod
        ),
        cartLineIDs: cartLineIDs,
        refreshEpoch: refreshEpoch(of: .shippingQuote)
      )
    )
    return model.shippingQuote
  }

  /// The accepted tax quote, demanding it.
  func taxQuoteValue() -> TaxQuote {
    let cartLineIDs = cartLineIDs()
    guard !cartLineIDs.isEmpty else {
      demandNothing(.taxQuote)
      return .pending
    }
    demand(
      .taxQuote,
      RawObservationAsyncDemand(
        request: .taxQuote(
          subtotalCents: discountedSubtotal(),
          market: model.shippingAddress.market
        ),
        cartLineIDs: cartLineIDs,
        refreshEpoch: refreshEpoch(of: .taxQuote)
      )
    )
    return model.taxQuote
  }

  // MARK: - Recording demand

  /// Records that the current observer pass wants one slot's value.
  ///
  /// Silent outside an observer pass, which is what makes the two settled
  /// inspections the trace takes genuinely untracked: a checkpoint reading a
  /// price must not start a request the session never asked for.
  ///
  /// - Parameters:
  ///   - slot: Which asynchronous value.
  ///   - demand: What it would ask the service for.
  func demand(_ slot: RawObservationAsyncSlot, _ demand: RawObservationAsyncDemand) {
    guard isCollectingDemand else { return }
    pendingDemand[slot] = demand
    pendingGuards.remove(slot)
  }

  /// Records that the current observer pass looked at a slot and found nothing
  /// to ask for.
  ///
  /// Distinct from not looking at all: a guarded read rests the value on its
  /// declaration default, matching the Cog selector that returns its default
  /// without scheduling, whereas an unread slot keeps whatever it last accepted.
  ///
  /// - Parameter slot: Which asynchronous value.
  func demandNothing(_ slot: RawObservationAsyncSlot) {
    guard isCollectingDemand else { return }
    guard pendingDemand[slot] == nil else { return }
    pendingGuards.insert(slot)
  }

  /// How many times one slot's demand has been re-asked explicitly.
  ///
  /// - Parameter slot: Which asynchronous value.
  /// - Returns: The slot's refresh epoch, zero if it has never been refreshed.
  func refreshEpoch(of slot: RawObservationAsyncSlot) -> Int {
    records[slot]?.refreshEpoch ?? 0
  }

  // MARK: - Reconciliation

  /// Starts, replaces, or clears each slot's request to match what the render
  /// asked for.
  ///
  /// Runs at the close of every render, synchronously, on the MainActor, so
  /// every selection reaches ``StorefrontService/schedule(_:)`` before any task
  /// launches — which is what lets the scripted driver see and release work by
  /// name. A slot whose demand is unchanged is left alone: that is the
  /// request-identity cache, and without it every render would re-ask the
  /// service for answers it already has.
  ///
  /// A slot nobody read is left alone too, in both directions — its value stays
  /// and its request is not replaced — because this port releases nothing.
  func reconcileAsyncDemand() {
    for (slot, wanted) in pendingDemand {
      var record = records[slot] ?? RawObservationAsyncRecord()
      guard record.demand != wanted else { continue }
      record.demand = wanted
      record.generation += 1
      records[slot] = record
      supersedePendingRefresh(for: slot)
      start(slot, request: wanted.request, generation: record.generation)
    }
    for slot in pendingGuards {
      var record = records[slot] ?? RawObservationAsyncRecord()
      guard record.demand != nil else { continue }
      record.demand = nil
      record.generation += 1
      records[slot] = record
      supersedePendingRefresh(for: slot)
      resetValue(for: slot)
    }
  }

  /// Re-asks one slot's question even though nothing about the world changed.
  ///
  /// What ``StorefrontRuntime/refreshCatalog()`` and
  /// ``StorefrontRuntime/refreshInventory(for:)`` mean. It starts the request
  /// directly rather than waiting for the next render, because an explicit
  /// re-demand is a user action and the value it refreshes may not be on screen
  /// at all.
  ///
  /// - Parameters:
  ///   - slot: Which asynchronous value.
  ///   - request: What to ask the service for.
  func forceDemand(_ slot: RawObservationAsyncSlot, request: StorefrontRequestID) {
    var record = records[slot] ?? RawObservationAsyncRecord()
    record.refreshEpoch += 1
    record.generation += 1
    record.demand = RawObservationAsyncDemand(
      request: request,
      catalogEpoch: catalogEpoch,
      shopperEpoch: shopperEpoch,
      refreshEpoch: record.refreshEpoch
    )
    records[slot] = record
    supersedePendingRefresh(for: slot)
    start(slot, request: request, generation: record.generation)
  }

  /// Rests one slot's value on its declaration default.
  ///
  /// The counterpart of a Cog selector that short-circuits to `.run { default }`:
  /// clearing a query has to clear the suggestions it produced, or the field
  /// would keep offering answers to a question nobody is asking any more.
  ///
  /// - Parameter slot: Which asynchronous value.
  private func resetValue(for slot: RawObservationAsyncSlot) {
    switch slot {
    case .catalog: model.catalog = .empty
    case .account: model.account = nil
    case .searchIndex: model.searchIndex = .empty
    case .suggestions: model.suggestions = []
    case .recommendations: model.recommendations = []
    case .inventory(let id): model.inventory[id] = .unknown
    case .offer(let id): model.offers[id] = PersonalizedOffer.none
    case .detail(let id): model.details[id] = .empty
    case .shippingQuote: model.shippingQuote = .pending
    case .taxQuote: model.taxQuote = .pending
    }
  }

  // MARK: - Requests

  /// Schedules one request and launches the task that will answer it.
  ///
  /// Every dependency the request body needs is captured **here**, synchronously
  /// and on the MainActor, exactly as a Cog async selector captures its reads
  /// before handing back `.run { @concurrent … }`. Nothing inside the task
  /// touches this runtime's state.
  ///
  /// - Parameters:
  ///   - slot: Which asynchronous value is being asked about.
  ///   - request: The identity to ask for.
  ///   - generation: The generation this answer will be checked against.
  func start(
    _ slot: RawObservationAsyncSlot,
    request: StorefrontRequestID,
    generation: Int
  ) {
    let service = model.service
    service.schedule(request)

    switch slot {
    case .catalog:
      perform(slot, generation: generation) { @concurrent in
        try await service.catalog()
      } accept: { [self] catalog in
        acceptCatalog(catalog)
      }

    case .account:
      perform(slot, generation: generation) { @concurrent in
        try await service.account()
      } accept: { [self] account in
        model.account = account
      }

    case .searchIndex:
      let products = catalogProducts()
      perform(slot, generation: generation) { @concurrent in
        try await service.searchIndex(products: products)
      } accept: { [self] searchIndex in
        model.searchIndex = searchIndex
      }

    case .suggestions:
      guard case .suggestions(let query) = request else {
        fatalError(
          "The raw Observation Storefront runtime asked \(request) on the suggestion slot.")
      }
      let products = catalogProducts()
      perform(slot, generation: generation) { @concurrent in
        try await service.suggestions(query: query, products: products)
      } accept: { [self] suggestions in
        model.suggestions = suggestions
      }

    case .recommendations:
      guard let shopper = model.signedInShopper else {
        fatalError(
          "The raw Observation Storefront runtime asked for recommendations while signed out."
        )
      }
      let products = catalogProducts()
      perform(slot, generation: generation) { @concurrent in
        try await service.recommendations(products: products, shopper: shopper)
      } accept: { [self] recommendations in
        model.recommendations = recommendations
      }

    case .inventory(let id):
      guard case .inventory(_, let inventoryGeneration) = request else {
        fatalError("The raw Observation Storefront runtime asked \(request) on an inventory slot.")
      }
      perform(slot, generation: generation) { @concurrent in
        try await service.inventory(for: id, generation: inventoryGeneration)
      } accept: { [self] inventory in
        model.inventory[id] = inventory
      }

    case .offer(let id):
      guard let shopper = model.signedInShopper else {
        fatalError("The raw Observation Storefront runtime asked for an offer while signed out.")
      }
      perform(slot, generation: generation) { @concurrent in
        try await service.offer(for: id, shopper: shopper)
      } accept: { [self] offer in
        model.offers[id] = offer
      }

    case .detail(let id):
      guard let product = productIndex()[id] else {
        fatalError(
          "The raw Observation Storefront runtime asked for the detail payload of \(id), which is not in the catalog."
        )
      }
      perform(slot, generation: generation) { @concurrent in
        try await service.detail(for: product)
      } accept: { [self] detail in
        model.details[id] = detail
      }

    case .shippingQuote:
      guard case .shippingQuote(let subtotalCents, _, let method) = request else {
        fatalError("The raw Observation Storefront runtime asked \(request) on the shipping slot.")
      }
      let address = model.shippingAddress
      let lineCount = cartLineIDs().count
      perform(slot, generation: generation) { @concurrent in
        try await service.shippingQuote(
          subtotalCents: subtotalCents,
          address: address,
          method: method,
          lineCount: lineCount
        )
      } accept: { [self] shippingQuote in
        model.shippingQuote = shippingQuote
      }

    case .taxQuote:
      guard case .taxQuote(let subtotalCents, _) = request else {
        fatalError("The raw Observation Storefront runtime asked \(request) on the tax slot.")
      }
      let address = model.shippingAddress
      perform(slot, generation: generation) { @concurrent in
        try await service.taxQuote(discountedSubtotalCents: subtotalCents, address: address)
      } accept: { [self] taxQuote in
        model.taxQuote = taxQuote
      }
    }
  }

  /// Runs one request off the MainActor and brings its result back to decide
  /// about it.
  ///
  /// The work closure is `@concurrent` so the heavy kernels — indexing the
  /// catalog, scoring it against a taste vector — leave the MainActor, exactly
  /// as the Cog port's `.run { @concurrent … }` bodies do. A comparison that ran
  /// them on the MainActor in one runtime and off it in another would be
  /// measuring where the work happened.
  ///
  /// - Parameters:
  ///   - slot: Which asynchronous value this answers.
  ///   - generation: The generation captured at selection time.
  ///   - work: The request body, run off the MainActor.
  ///   - accept: Publishes an accepted value. Runs on the MainActor, and only
  ///     when the generation is still current.
  private func perform<Value: Sendable>(
    _ slot: RawObservationAsyncSlot,
    generation: Int,
    work: @escaping @Sendable @concurrent () async throws -> Value,
    accept: @escaping @Sendable @MainActor (Value) -> Void
  ) {
    Task { @MainActor in
      let outcome: Result<Value, any Error>
      do {
        outcome = .success(try await work())
      } catch {
        outcome = .failure(error)
      }
      self.finish(slot, generation: generation, outcome: outcome, accept: accept)
    }
  }

  /// Decides about one completed request, then fires the armed barrier.
  ///
  /// The generation captured at selection time is compared with the slot's
  /// current one, and the value is published only when they still agree. That is
  /// the whole of this port's staleness rule: no cancellation, no cooperation
  /// from the old task, and therefore nothing that a request script leaving
  /// cancelled work suspended can defeat.
  ///
  /// The barrier fires on **both** branches, because a stale result the runtime
  /// deliberately refuses is exactly as much of a decision as one it publishes —
  /// and the search phase's stale step is built on being able to wait for it.
  /// Rendering happens before the barrier fires, so the trace's next line reads
  /// a settled sink.
  ///
  /// - Parameters:
  ///   - slot: Which asynchronous value this answers.
  ///   - generation: The generation captured at selection time.
  ///   - outcome: What the request produced.
  ///   - accept: Publishes an accepted value.
  private func finish<Value>(
    _ slot: RawObservationAsyncSlot,
    generation: Int,
    outcome: Result<Value, any Error>,
    accept: @MainActor (Value) -> Void
  ) {
    if (records[slot]?.generation ?? 0) == generation {
      switch outcome {
      case .success(let value):
        accept(value)
        if slot == .recommendations {
          resolvePendingRefresh(generation: generation, with: .success(model.recommendations))
        }
        render()
      case .failure(let error):
        // A value read is total, so a failed generation leaves the last
        // accepted success in place and nothing on screen moves. Cog reports
        // the failure through its status lens, which no observer in this
        // workload reads.
        if slot == .recommendations {
          resolvePendingRefresh(generation: generation, with: .failure(error))
        }
      }
    }
    armedCompletionSignal?.signal()
    armedCompletionSignal = nil
  }

  /// Publishes an accepted catalog and notes whether it was a different one.
  ///
  /// The epoch advances only on an actual change, which is what a hand-written
  /// app's `didAcceptCatalog` means and what keeps a reload returning an equal
  /// catalog from re-asking for the search index, every suggestion, and every
  /// detail payload downstream of it.
  ///
  /// - Parameter catalog: The accepted catalog.
  private func acceptCatalog(_ catalog: CatalogSnapshot) {
    let isDifferent = model.catalog != catalog
    model.catalog = catalog
    if isDifferent { catalogEpoch += 1 }
  }

  // MARK: - Refresh handles

  /// Resolves the outstanding recommendation handle as superseded, if the slot
  /// being replaced is the one it names.
  ///
  /// Called at the moment of replacement rather than when the replaced task
  /// eventually finishes, which is what makes the teardown phase's checkpoint a
  /// definite signal instead of a race.
  ///
  /// - Parameter slot: The slot whose generation just advanced.
  func supersedePendingRefresh(for slot: RawObservationAsyncSlot) {
    guard slot == .recommendations, let pending = pendingRecommendationsRefresh else { return }
    pendingRecommendationsRefresh = nil
    pending.handle.resolve(.superseded)
  }

  /// Resolves the outstanding recommendation handle with a terminal outcome.
  ///
  /// Only the generation this handle names may resolve it. A later generation
  /// has its own handle, and an earlier one was already resolved as superseded
  /// when it was replaced.
  ///
  /// - Parameters:
  ///   - generation: The generation that completed.
  ///   - outcome: What to resolve the handle with.
  private func resolvePendingRefresh(
    generation: Int,
    with outcome: StorefrontRefreshOutcome<[ProductID]>
  ) {
    guard let pending = pendingRecommendationsRefresh else { return }
    guard pending.generation == generation else { return }
    pendingRecommendationsRefresh = nil
    pending.handle.resolve(outcome)
  }
}
