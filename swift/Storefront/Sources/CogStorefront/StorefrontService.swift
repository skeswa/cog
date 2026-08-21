import os

/// The deterministic request boundary every async declaration in the workload
/// selects.
///
/// This is a benchmark-only service and it never touches a network, a clock, or
/// a random number generator. Every response is a pure function of the fixture
/// seed and the request's own inputs, and — in ``Mode/scripted`` — every
/// response is delivered exactly when the driver says so, by name.
///
/// That last property is what makes the headless driver deterministic rather
/// than merely repeatable. Sibling tasks start in whatever order the
/// concurrency runtime picks, so a driver that assumed "catalog resolves before
/// account" would be asserting on scheduling luck. Instead the driver awaits
/// the exact *set* of requests that has started, and then releases them one at
/// a time in a fixed, deliberately out-of-order sequence.
///
/// `Sendable` because it crosses into `@concurrent` work; it is a thin handle
/// around one actor, so copying it shares the script rather than forking it.
public nonisolated struct StorefrontService: Sendable {
  /// How the service answers.
  public enum Mode: Sendable, Equatable {
    /// Answer immediately, in whatever order the runtime resumes tasks.
    ///
    /// What the SwiftUI application uses. The content is still perfectly
    /// deterministic; only the *timing* is the runtime's business, which is
    /// the honest model for an app that a UI test drives through its
    /// interface rather than through its request boundary.
    case immediate

    /// Answer only when the driver releases the request by name.
    ///
    /// What the headless driver uses, and the reason its checkpoints can
    /// promise an exact set of accepted generations.
    case scripted
  }

  /// The world this service serves.
  ///
  /// Carried here rather than in a thirteenth manual source: the profile is a
  /// property of the fixtures the service returns, and every selector that
  /// needs it already reads the service.
  public let profile: StorefrontProfile

  /// The script and its request bookkeeping.
  let script: StorefrontScript

  /// Creates a service over a fresh script.
  ///
  /// - Parameters:
  ///   - profile: The world to serve.
  ///   - mode: Whether responses wait to be released.
  public init(profile: StorefrontProfile, mode: Mode = .immediate) {
    self.profile = profile
    script = StorefrontScript(mode: mode)
  }

  /// Registers work selected synchronously by the graph before its task starts.
  ///
  /// Selection and execution are two different scheduler events. Recording the
  /// request here closes the gap between them: the scripted driver can see and
  /// release work even when Cog has created its task but that task has not yet
  /// reached ``StorefrontScript/begin(_:)``. Immediate services record through
  /// the same path so both modes exercise identical bookkeeping.
  ///
  /// - Parameter id: The semantic request the selector chose.
  func schedule(_ id: StorefrontRequestID) {
    script.schedule(id)
  }

  // MARK: - Requests

  /// The catalog. One request per session, at the root of the graph.
  public func catalog() async throws -> CatalogSnapshot {
    try await script.begin(.catalog)
    return StorefrontFixtures.catalog(for: profile)
  }

  /// The signed-in shopper. The other root request.
  public func account() async throws -> Shopper {
    try await script.begin(.account)
    return StorefrontFixtures.shopper(for: profile)
  }

  /// The inverted search index, built off the MainActor.
  ///
  /// - Parameter products: The catalog to index.
  /// - Returns: The index.
  public func searchIndex(products: [Product]) async throws -> StorefrontKernels.SearchIndex {
    try await script.begin(.searchIndex)
    return StorefrontKernels.buildSearchIndex(products: products)
  }

  /// Suggestions for one exact query.
  ///
  /// The query is part of the request identity, which is what lets the driver
  /// complete a *stale* generation on purpose and prove the graph refuses it.
  ///
  /// - Parameters:
  ///   - query: The raw query the shopper has typed.
  ///   - products: The catalog to suggest from.
  /// - Returns: Suggestion strings.
  public func suggestions(query: String, products: [Product]) async throws -> [String] {
    try await script.begin(.suggestions(query: query))
    return StorefrontKernels.suggestions(
      for: query,
      products: products,
      count: profile.suggestionCount
    )
  }

  /// Personalized recommendations, scored over the whole catalog.
  ///
  /// - Parameters:
  ///   - products: The catalog to score.
  ///   - shopper: Whose taste to score against.
  /// - Returns: Recommended product identifiers, best first.
  public func recommendations(products: [Product], shopper: Shopper) async throws -> [ProductID] {
    try await script.begin(.recommendations(accountID: shopper.accountID))
    return StorefrontKernels.recommend(
      products: products,
      taste: shopper.taste,
      count: profile.recommendationCount
    )
  }

  /// Live inventory for one product at one generation.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - generation: Which reading; the inventory burst advances this.
  /// - Returns: The reading.
  public func inventory(for id: ProductID, generation: Int) async throws -> InventoryReading {
    try await script.begin(.inventory(id: id, generation: generation))
    return StorefrontFixtures.inventory(for: id, generation: generation, profile: profile)
  }

  /// The personalized offer for one product.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - shopper: Whose offer.
  /// - Returns: The offer, often ``PersonalizedOffer/none``.
  public func offer(for id: ProductID, shopper: Shopper) async throws -> PersonalizedOffer {
    try await script.begin(.offer(id: id))
    return StorefrontFixtures.offer(for: id, shopper: shopper)
  }

  /// The detail-screen payload for one product.
  ///
  /// - Parameter product: Which product.
  /// - Returns: The payload.
  public func detail(for product: Product) async throws -> ProductDetail {
    try await script.begin(.detail(id: product.id))
    return StorefrontFixtures.detail(for: product)
  }

  /// A shipping quote for the settled cart.
  ///
  /// - Parameters:
  ///   - subtotalCents: The discounted subtotal.
  ///   - address: Where it ships.
  ///   - method: How fast.
  ///   - lineCount: How many lines are in the box.
  /// - Returns: The quote.
  public func shippingQuote(
    subtotalCents: Int,
    address: ShippingAddress,
    method: ShippingMethod,
    lineCount: Int
  ) async throws -> ShippingQuote {
    try await script.begin(
      .shippingQuote(subtotalCents: subtotalCents, market: address.market, method: method)
    )
    return StorefrontFixtures.shippingQuote(
      subtotalCents: subtotalCents,
      address: address,
      method: method,
      lineCount: lineCount
    )
  }

  /// A tax quote for the settled cart.
  ///
  /// - Parameters:
  ///   - discountedSubtotalCents: The amount being taxed.
  ///   - address: Which market's rate applies.
  /// - Returns: The quote.
  public func taxQuote(
    discountedSubtotalCents: Int,
    address: ShippingAddress
  ) async throws -> TaxQuote {
    try await script.begin(
      .taxQuote(subtotalCents: discountedSubtotalCents, market: address.market)
    )
    return StorefrontFixtures.taxQuote(
      discountedSubtotalCents: discountedSubtotalCents,
      address: address
    )
  }
}

/// What one request is, semantically.
///
/// A structured enum rather than a raw string so a driver naming a request
/// cannot typo one into never being released, and so the identity is exactly
/// the inputs a real backend would key on.
public nonisolated enum StorefrontRequestID: Hashable, Sendable, CustomStringConvertible {
  /// The catalog.
  case catalog
  /// The account.
  case account
  /// The search index over the catalog.
  case searchIndex
  /// Suggestions for one exact query string.
  case suggestions(query: String)
  /// Recommendations for one account.
  case recommendations(accountID: Int)
  /// Inventory for one product at one generation.
  case inventory(id: ProductID, generation: Int)
  /// The offer for one product.
  case offer(id: ProductID)
  /// The detail payload for one product.
  case detail(id: ProductID)
  /// A shipping quote for one cart shape.
  case shippingQuote(subtotalCents: Int, market: Int, method: ShippingMethod)
  /// A tax quote for one cart shape.
  case taxQuote(subtotalCents: Int, market: Int)

  public var description: String {
    switch self {
    case .catalog: "catalog"
    case .account: "account"
    case .searchIndex: "searchIndex"
    case .suggestions(let query): "suggestions(\(query))"
    case .recommendations(let accountID): "recommendations(\(accountID))"
    case .inventory(let id, let generation): "inventory(\(id)@\(generation))"
    case .offer(let id): "offer(\(id))"
    case .detail(let id): "detail(\(id))"
    case .shippingQuote(let subtotal, let market, let method):
      "shippingQuote(\(subtotal)/\(market)/\(method.rawValue))"
    case .taxQuote(let subtotal, let market): "taxQuote(\(subtotal)/\(market))"
    }
  }
}

/// The actor that records requests and releases them by name.
///
/// Every suspended request holds one ticket. Tickets exist because the same
/// semantic request can legitimately be in flight twice — a product's inventory
/// is demanded, released, invalidated, and demanded again at the same
/// generation — and a dictionary keyed only by request identity would lose the
/// first continuation and hang the run.
public actor StorefrontScript {
  /// Synchronously selected work that has not reached ``begin(_:)`` yet.
  ///
  /// This ledger is lock-backed rather than actor-isolated because an async-cog
  /// selector must register its request synchronously on the MainActor before it
  /// hands Cog a task. The actor consumes the matching entry as the task begins.
  private nonisolated let scheduled = OSAllocatedUnfairLock(initialState: ScheduledState())

  /// Mutable state protected by ``scheduled``.
  private struct ScheduledState {
    /// How many selected tasks of each identity have not begun.
    var counts: [StorefrontRequestID: Int] = [:]

    /// Every not-yet-begun task in selection order.
    var order: [StorefrontRequestID] = []
  }

  /// How this script answers.
  private let mode: StorefrontService.Mode

  /// The next ticket to hand out.
  private var nextTicket = 0

  /// Suspended requests, by ticket.
  private var suspended: [Int: CheckedContinuation<Void, any Error>] = [:]

  /// Tickets waiting on each request identity, oldest first.
  private var queued: [StorefrontRequestID: [Int]] = [:]

  /// How many times each request has started, ever.
  private var startCounts: [StorefrontRequestID: Int] = [:]

  /// Every request that has started, in start order, for diagnostics.
  private var startOrder: [StorefrontRequestID] = []

  /// Requests released before they started; the next start returns at once.
  private var releasedEarly: [StorefrontRequestID: Int] = [:]

  /// Requests cancelled before their continuation was installed.
  private var cancelledEarly: Set<Int> = []

  /// Whether a cancelled request stays suspended instead of throwing.
  ///
  /// On by default, and that default is what makes the headless driver
  /// deterministic. Cog's `.latest` policy cancels a superseded task, and a
  /// task that resumed on cancellation would complete on another thread at a
  /// moment nothing controls — racing the one-shot async-completion
  /// acknowledgement the driver arms before each release. Leaving a cancelled
  /// request suspended means the driver releases *every* completion by name,
  /// and it buys a second thing for free: releasing a superseded request later
  /// is exactly the stale completion Cog promises to refuse by generation.
  ///
  /// A driver turns it off around a step whose subject *is* cancellation.
  private var ignoresCancellation = true

  /// Drivers waiting for a set of requests to have started.
  private var startWaiters:
    [(needed: [StorefrontRequestID], resume: CheckedContinuation<Void, Never>)] = []

  /// Creates a script.
  ///
  /// - Parameter mode: Whether responses wait to be released.
  public init(mode: StorefrontService.Mode) {
    self.mode = mode
  }

  // MARK: - The request side

  /// Records one synchronously selected request before Cog launches its task.
  ///
  /// Nonisolated so the async selector can make the request visible without an
  /// actor hop. ``begin(_:)`` consumes exactly one matching entry later.
  ///
  /// - Parameter id: The semantic request the selector chose.
  nonisolated func schedule(_ id: StorefrontRequestID) {
    scheduled.withLock { state in
      state.counts[id, default: 0] += 1
      state.order.append(id)
    }
  }

  /// Removes one scheduled entry as its task reaches the service actor.
  ///
  /// - Parameter id: The request that began.
  private nonisolated func consumeScheduled(_ id: StorefrontRequestID) {
    scheduled.withLock { state in
      guard let count = state.counts[id], count > 0 else {
        fatalError("The Storefront service began \(id) without scheduling it first.")
      }
      if count == 1 {
        state.counts.removeValue(forKey: id)
      } else {
        state.counts[id] = count - 1
      }
      guard let index = state.order.firstIndex(of: id) else {
        fatalError("The Storefront scheduled-request order lost \(id).")
      }
      state.order.remove(at: index)
    }
  }

  /// Records that a request started, and — in `scripted` mode — waits.
  ///
  /// - Parameter id: What started.
  func begin(_ id: StorefrontRequestID) async throws {
    consumeScheduled(id)
    startCounts[id, default: 0] += 1
    startOrder.append(id)
    resumeSatisfiedStartWaiters()

    guard mode == .scripted else { return }
    if let remaining = releasedEarly[id], remaining > 0 {
      releasedEarly[id] = remaining - 1
      return
    }

    let ticket = nextTicket
    nextTicket += 1
    queued[id, default: []].append(ticket)

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if cancelledEarly.remove(ticket) != nil {
          drop(ticket: ticket, from: id)
          continuation.resume(throwing: CancellationError())
          return
        }
        suspended[ticket] = continuation
      }
    } onCancel: {
      Task { await self.cancel(ticket: ticket, of: id) }
    }
  }

  /// Cancels one suspended ticket, or remembers to cancel it on arrival.
  ///
  /// - Parameters:
  ///   - ticket: Which suspension.
  ///   - id: Which request it belongs to.
  private func cancel(ticket: Int, of id: StorefrontRequestID) {
    guard !ignoresCancellation else { return }
    if let continuation = suspended.removeValue(forKey: ticket) {
      drop(ticket: ticket, from: id)
      continuation.resume(throwing: CancellationError())
      return
    }
    cancelledEarly.insert(ticket)
  }

  /// Removes one ticket from a request's queue.
  private func drop(ticket: Int, from id: StorefrontRequestID) {
    guard var tickets = queued[id] else { return }
    tickets.removeAll { $0 == ticket }
    if tickets.isEmpty {
      queued.removeValue(forKey: id)
    } else {
      queued[id] = tickets
    }
  }

  // MARK: - The driver side

  /// Waits until every named request has started at least `ids` many times.
  ///
  /// This is the barrier that replaces assuming sibling task start order. A
  /// driver calls it with the exact set it expects, so a graph that stopped
  /// demanding one of them hangs the run rather than silently measuring a
  /// smaller workload.
  ///
  /// - Parameter ids: The requests to wait for; duplicates mean "twice".
  public func awaitStarted(_ ids: [StorefrontRequestID]) async {
    guard !isSatisfied(ids) else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((needed: ids, resume: continuation))
    }
  }

  /// Whether every request in `ids` has started at least as often as it appears.
  private func isSatisfied(_ ids: [StorefrontRequestID]) -> Bool {
    var required: [StorefrontRequestID: Int] = [:]
    for id in ids { required[id, default: 0] += 1 }
    return required.allSatisfy { startCounts[$0.key, default: 0] >= $0.value }
  }

  /// Resumes every start waiter whose set is now complete.
  private func resumeSatisfiedStartWaiters() {
    var stillWaiting: [(needed: [StorefrontRequestID], resume: CheckedContinuation<Void, Never>)] =
      []
    for waiter in startWaiters {
      if isSatisfied(waiter.needed) {
        waiter.resume.resume()
      } else {
        stillWaiting.append(waiter)
      }
    }
    startWaiters = stillWaiting
  }

  /// Chooses whether a cancelled request resumes or stays suspended.
  ///
  /// - Parameter value: `true` to leave cancelled requests suspended, which is
  ///   the deterministic default; `false` for a step whose subject is
  ///   cancellation itself.
  public func setIgnoresCancellation(_ value: Bool) {
    ignoresCancellation = value
  }

  /// Releases the oldest suspended request with this identity.
  ///
  /// Releasing an identity that has not started yet is legal and is recorded:
  /// the next start of that identity returns immediately. That is what lets a
  /// driver script an out-of-order release without first proving which sibling
  /// won the scheduler.
  ///
  /// - Parameter id: What to release.
  public func release(_ id: StorefrontRequestID) {
    guard var tickets = queued[id], let ticket = tickets.first else {
      releasedEarly[id, default: 0] += 1
      return
    }
    tickets.removeFirst()
    if tickets.isEmpty {
      queued.removeValue(forKey: id)
    } else {
      queued[id] = tickets
    }
    suspended.removeValue(forKey: ticket)?.resume()
  }

  /// Releases several requests, in exactly the order given.
  ///
  /// - Parameter ids: The release order, which the driver chooses to be
  ///   deliberately different from the start order.
  public func release(_ ids: [StorefrontRequestID]) {
    for id in ids { release(id) }
  }

  /// Fails the oldest suspended request with this identity.
  ///
  /// - Parameters:
  ///   - id: What to fail.
  ///   - error: What it fails with.
  public func fail(_ id: StorefrontRequestID, with error: any Error) {
    guard var tickets = queued[id], let ticket = tickets.first else { return }
    tickets.removeFirst()
    if tickets.isEmpty {
      queued.removeValue(forKey: id)
    } else {
      queued[id] = tickets
    }
    suspended.removeValue(forKey: ticket)?.resume(throwing: error)
  }

  /// Releases every currently suspended request, oldest first.
  public func releaseAll() {
    for id in pendingRequestIDs {
      release(id)
    }
  }

  // MARK: - Inspection

  /// Whether this identity is selected or suspended and can therefore be released.
  ///
  /// A driver checks this before releasing, because releasing an identity that
  /// is not suspended is silently recorded as an early release — and a driver
  /// that then awaited a completion would wait forever. Turning that mistake
  /// into a loud failure is worth one extra actor hop.
  ///
  /// - Parameter id: Which request.
  /// - Returns: Whether it can be released now.
  public func isPending(_ id: StorefrontRequestID) -> Bool {
    if queued[id]?.isEmpty == false { return true }
    return scheduled.withLock { $0.counts[id, default: 0] > 0 }
  }

  /// How many times a request has started.
  ///
  /// - Parameter id: Which request.
  /// - Returns: The count.
  public func startCount(of id: StorefrontRequestID) -> Int {
    startCounts[id, default: 0]
  }

  /// Every request that has started, in start order.
  ///
  /// For diagnostics and for the checkpoints that assert no duplicate work; a
  /// driver must never *depend* on this order, only assert against it.
  public var startedRequests: [StorefrontRequestID] { startOrder }

  /// How many requests are suspended right now.
  public var suspendedCount: Int { suspended.count }

  /// Selected or suspended requests that have not completed yet.
  public var outstandingCount: Int {
    suspended.count + scheduled.withLock { state in state.counts.values.reduce(0, +) }
  }

  /// Declared explicitly rather than synthesized, matching the repository's
  /// rule for every other reference type here. An actor's deinit is nonisolated
  /// by default, so this changes nothing today; it exists so a reader does not
  /// have to know that to be sure.
  nonisolated deinit {}

  /// Every request identity with selected or suspended work, in demand order.
  ///
  /// A driver releases from this list *reversed*, which is the cheapest honest
  /// way to be deliberately out of order: the newest request lands first and
  /// the oldest last, so nothing in the graph can be relying on completion
  /// order matching request order.
  public var pendingRequestIDs: [StorefrontRequestID] {
    var seen: Set<StorefrontRequestID> = []
    var result: [StorefrontRequestID] = []
    for id in startOrder where queued[id] != nil {
      if seen.insert(id).inserted { result.append(id) }
    }
    let scheduledOrder = scheduled.withLock { $0.order }
    for id in scheduledOrder where seen.insert(id).inserted {
      result.append(id)
    }
    return result
  }
}
