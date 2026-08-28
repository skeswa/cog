import StorefrontWorkload

/// One runtime's complete record of one Storefront session, reduced to the
/// values four runtimes must agree on.
///
/// A value type with no identity: it is produced by
/// ``observeAgreementSession(_:profile:)``, held in an array beside three
/// siblings, and compared field by field. It deliberately carries *only*
/// runtime-invariant outputs plus the runtime's own declarations. Nothing here
/// is a run count, a cache size, a node count, or any other figure that is
/// legitimately a property of the implementation strategy rather than of the
/// shopping session, a suite that compared those would fail four ways for
/// three correct reasons and one real one.
///
/// The shadow's answers travel alongside the runtime's rather than being
/// recomputed at comparison time. Each session builds its own
/// ``StorefrontWorld`` from the same profile and the same events, so the four
/// shadows are themselves a fifth thing that must agree; carrying them makes
/// that checkable instead of assumed.
struct RuntimeAgreementObservation: Sendable {
  /// What the runtime calls itself and what it guarantees.
  let descriptor: StorefrontRuntimeDescriptor

  /// What was on screen at each of the eleven phase boundaries, in order.
  let phaseRenderings: [PhaseRendering]

  /// The products the last browse run put on screen, in list order.
  let visibleProductIDs: [ProductID]

  /// The order-sensitive digest of every visible row's rendered content.
  let visibleChecksum: Int

  /// The suggestions the last search run settled on.
  let suggestions: [String]

  /// The cart's money as of the last cart run.
  let orderTotal: OrderTotal

  /// How many requests the script still had outstanding when the session ended.
  ///
  /// Must be zero. A lower count can also reveal skipped requests even when the
  /// rendered output matches.
  let outstandingRequestCount: Int

  /// Every checkpoint the trace recorded that did not hold.
  let checkpointFailures: [StorefrontCheckpoint]

  /// The names of the checkpoints this runtime was excused from, in order.
  ///
  /// Recorded rather than tolerated: a skip registers as holding, so an
  /// unexamined skip is how a claim stops being checked without anyone reading
  /// a failure.
  let skippedCheckpointNames: [String]

  /// How many checkpoints the trace recorded in total.
  ///
  /// Compared across runtimes because the trace is one script: a runtime that
  /// recorded fewer claims than its siblings took a branch the others did not.
  let checkpointCount: Int

  /// What the shared shadow said was on screen when the session ended.
  let shadowVisibleProductIDs: [ProductID]

  /// What the shared shadow said the visible digest was.
  let shadowVisibleChecksum: Int

  /// What the shared shadow said the suggestions were.
  let shadowSuggestions: [String]

  /// What the shared shadow said the cart's money was.
  let shadowOrderTotal: OrderTotal

  /// Whether the shadow's cart had lines in it when the session ended.
  ///
  /// Only non-empty carts have comparable order totals, as
  /// ``StorefrontSessionDriver/requireSettledOutput(against:)`` requires. Empty
  /// carts have no shipping or tax quotes.
  let shadowCartIsEmpty: Bool

  /// How this runtime is named in a failure message.
  var slug: String { descriptor.slug }

  /// What this runtime had rendered at one named boundary.
  ///
  /// By name rather than by index, so a phase inserted into the trace shifts
  /// nothing silently.
  ///
  /// - Parameter phase: The boundary.
  /// - Returns: The rendering, or `nil` if this session never reached it.
  func rendering(after phase: StorefrontPhase) -> PhaseRendering? {
    phaseRenderings.first { $0.phase == phase }
  }
}

/// What one phase boundary put on screen, and what the shadow said it should
/// have.
///
/// Captures the phase, checksum, visible IDs, cart money, and shadow answers at
/// one instant. A failure can name products without rebuilding past state.
struct PhaseRendering: Sendable, Equatable {
  /// Which boundary this is.
  let phase: StorefrontPhase

  /// The products on screen at that boundary, in list order.
  let visibleProductIDs: [ProductID]

  /// The digest of their rendered content.
  let visibleChecksum: Int

  /// The cart's money at that boundary.
  let orderTotal: OrderTotal

  /// What the shadow said was on screen at that boundary.
  let shadowVisibleProductIDs: [ProductID]

  /// What the shadow said the digest was.
  let shadowVisibleChecksum: Int

  /// What the shadow said the cart's money was.
  let shadowOrderTotal: OrderTotal

  /// Whether the shadow's cart had lines in it at that boundary.
  ///
  /// Only non-empty carts have comparable order totals, as
  /// ``StorefrontSessionDriver/requireSettledOutput(against:)`` requires. Empty
  /// carts have no shipping or tax quotes.
  let shadowCartIsEmpty: Bool
}

/// Runs the eleven-phase trace against one runtime and records what it settled
/// to.
///
/// Generic over ``StorefrontRuntime`` because that is the only way one function
/// can drive four runtimes whose `Refresh` associated types differ, and driving
/// all four through one function is the point: a second, copied driver loop is
/// how two sessions quietly stop being the same session.
///
/// ## Why the phases are run individually
///
/// ``StorefrontSessionDriver/runStandardTrace()`` calls exactly these eleven
/// methods in exactly this order. They are spelled out here so that the sink can
/// be read *between* them. A runtime that diverged in the middle and converged
/// again by the last phase would pass an end-of-session comparison while having
/// rendered screens nobody asked for, and the whole reason to compare four
/// runtimes is to catch the divergence rather than the convergence. The suite
/// asserts that the recorded phases are exactly ``StorefrontPhase/allCases``, so
/// a phase added to the trace and not to this function fails loudly.
///
/// ## Why nothing here traps
///
/// The driver's own gates, `requireCheckpointsHold()` and
/// `requireSettledOutput(against:)`, are `fatalError`s, which is right for a
/// benchmark cut whose timing would otherwise be meaningless. It is wrong here:
/// this function is called four times before anything is compared, and a trap in
/// the second call would kill the process before the suite could say which
/// runtimes disagreed about what. So every claim those two methods make is
/// captured as a value instead and asserted by the suite, which reports all of
/// them and then fails. Nothing is checked less; it is checked later and out
/// loud.
///
/// - Parameters:
///   - runtime: The runtime type to build a session around.
///   - profile: The world's size. `smoke` is the profile the correctness gate is
///     defined on, and it still exercises every structure the reported profiles
///     do, several categories, the full pricing ladder, a cart with
///     promotions, and both halves of an inventory burst.
/// - Returns: Everything the suite compares.
func observeAgreementSession<Runtime: StorefrontRuntime>(
  _ runtime: Runtime.Type,
  profile: StorefrontProfile = .smoke
) async throws -> RuntimeAgreementObservation {
  let driver = StorefrontSessionDriver<Runtime>(profile: profile)
  var renderings: [PhaseRendering] = []

  /// Captures what the sink holds at one boundary, beside what the shadow does.
  func record(_ phase: StorefrontPhase) {
    renderings.append(
      PhaseRendering(
        phase: phase,
        visibleProductIDs: driver.sink.visibleProductIDs,
        visibleChecksum: driver.sink.visibleChecksum,
        orderTotal: driver.sink.orderTotal,
        shadowVisibleProductIDs: driver.world.visibleProductIDs,
        shadowVisibleChecksum: driver.world.visibleChecksum,
        shadowOrderTotal: driver.world.orderTotal(),
        shadowCartIsEmpty: driver.world.cartLines.isEmpty
      )
    )
  }

  try await driver.runBootstrapPhase()
  record(.bootstrap)
  try await driver.runRootDataPhase()
  record(.rootData)
  try await driver.runInitialRowDataPhase()
  record(.initialRowData)
  try await driver.runScrollPhase()
  record(.scroll)
  try await driver.runSearchPhase()
  record(.search)
  try await driver.runFilterPhase()
  record(.filters)
  try await driver.runCartPhase()
  record(.cart)
  try await driver.runDetailPhase()
  record(.detail)
  try await driver.runCheckoutPhase()
  record(.checkout)
  try await driver.runBurstPhase()
  record(.burst)
  try await driver.runTeardownPhase()
  record(.teardown)

  let world = driver.world
  let normalizedQuery = StorefrontKernels.normalize(world.query)
  let shadowSuggestions = StorefrontKernels.suggestions(
    for: normalizedQuery,
    products: world.catalog.products,
    count: profile.suggestionCount
  )

  return RuntimeAgreementObservation(
    descriptor: Runtime.descriptor,
    phaseRenderings: renderings,
    visibleProductIDs: driver.sink.visibleProductIDs,
    visibleChecksum: driver.sink.visibleChecksum,
    suggestions: driver.sink.suggestions,
    orderTotal: driver.sink.orderTotal,
    outstandingRequestCount: await driver.script.outstandingCount,
    checkpointFailures: driver.failures,
    skippedCheckpointNames: driver.checkpoints
      .filter { $0.expected.hasPrefix("not applicable") }
      .map(\.name),
    checkpointCount: driver.checkpoints.count,
    shadowVisibleProductIDs: world.visibleProductIDs,
    shadowVisibleChecksum: world.visibleChecksum,
    shadowSuggestions: shadowSuggestions,
    shadowOrderTotal: world.orderTotal(),
    shadowCartIsEmpty: world.cartLines.isEmpty
  )
}
