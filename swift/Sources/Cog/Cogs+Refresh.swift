// MARK: - Refreshing asynchronous values

/// A handle for the exact async generation started by ``Cogs/refresh(_:)``.
///
/// Awaiting ``outcome`` never drifts to a later request. Replacement resolves
/// this handle as ``Outcome/superseded``; lifetime release resolves it as
/// ``Outcome/released``. A completed outcome is retained by the handle, so it
/// remains safe to await after the graph has moved on.
public struct CogRefresh<Value> {
  /// How the exact requested generation finished.
  public nonisolated enum Outcome {
    /// Cog accepted and published the generation's value.
    case success(Value)

    /// Cog accepted and published the generation's error.
    case failure(any Error)

    /// Newer work or an invalidated selector made this generation stale.
    case superseded

    /// The owning state left the graph before this generation completed.
    case released
  }

  /// The single-assignment completion shared with the generation's state.
  private let waiter: CogRefreshWaiter<Value>

  /// Creates a public handle around Cog's internal completion cell.
  internal init(waiter: CogRefreshWaiter<Value>) {
    self.waiter = waiter
  }

  /// The terminal result of this exact generation.
  ///
  /// Multiple callers may await the same handle. Every caller receives the
  /// same retained outcome, including callers that arrive after completion.
  public var outcome: Outcome {
    get async { await waiter.wait() }
  }
}

/// A refresh outcome may cross isolation domains.
extension CogRefresh.Outcome: Sendable where Value: Sendable {}

/// The MainActor-confined single-assignment cell behind one refresh handle.
///
/// The async state owns the cell until it resolves; the public handle may keep
/// it afterward. Continuations are resumed exactly once and never escape the
/// MainActor unresolved.
internal final class CogRefreshWaiter<Value> {
  /// The public outcome type this cell stores.
  typealias Outcome = CogRefresh<Value>.Outcome

  /// The terminal outcome, once the generation finishes.
  private var resolvedOutcome: Outcome?

  /// Callers suspended before the terminal outcome existed.
  private var continuations: [CheckedContinuation<Void, Never>] = []

  /// Suspends until resolution, or returns an already retained outcome.
  func wait() async -> Outcome {
    if let resolvedOutcome {
      return resolvedOutcome
    }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    guard let resolvedOutcome else {
      fatalError("A refresh waiter resumed before receiving its outcome.")
    }
    return resolvedOutcome
  }

  /// Publishes the only terminal outcome and resumes every current waiter.
  func resolve(_ outcome: Outcome) {
    guard resolvedOutcome == nil else { return }
    resolvedOutcome = outcome
    let continuations = continuations
    self.continuations.removeAll(keepingCapacity: false)
    for continuation in continuations {
      continuation.resume()
    }
  }

  // Written out, and `nonisolated`, per the generic-class release rule.
  nonisolated deinit {}
}

/// Adds explicit one-shot async demand to a context.
///
/// Refresh uses the same state identity, scheduling policy, lifetime rules, and
/// MainActor turn machinery as reads; it differs only in forcing a new
/// generation after initial demand.
extension Cogs {
  /// Runs an async cog's selector and work again even when no dependency changed.
  ///
  /// Refresh enters the normal async settlement path. The selector reads its
  /// synchronous dependencies again, and pending, success, or failure is
  /// published in the same separate named turns as a dependency-triggered
  /// reload. Under `.latest`, the request cancels in-flight work and advances
  /// the generation before starting its replacement, so a late old result
  /// cannot publish.
  ///
  /// A never-read reference performs one initial load; it is not initialized
  /// and then immediately replaced. Refresh itself is one-shot demand: it adds
  /// neither a dependency edge nor an Observation boundary. If no reaction
  /// lease or UI boundary already keeps the exact state observed, the call
  /// starts or renews its ordinary `whileObserved` grace after selecting the
  /// work. The state owns at most one grace sleeper, so repeated transient
  /// demand cancels and replaces the prior deadline rather than accumulating
  /// tasks. An internal selector edge may defer removal at expiry, but it is not
  /// durable observation and does not earn another grace window.
  ///
  /// Call refresh from event handling or a reaction. A request made by a
  /// reaction queues its system turn until reaction tracking finishes, so
  /// status publication cannot reenter the active consumer. Calling it while any
  /// automatic or async selector is computing instead traps before the target
  /// state is created, using the same diagnostic as a turn during automatic computation.
  ///
  /// - Parameter valueReference: The keyless or keyed async identity to demand
  ///   again in this context.
  /// - Returns: A handle whose outcome belongs only to the generation this call
  ///   started. Retaining it does not retain the Cog state or add observation.
  @discardableResult
  public func refresh<Value>(_ valueReference: Cog<Value>.Async) -> CogRefresh<Value> {
    requireOutsideAutomaticComputation(forTurnNamed: #function)
    return arenaCore.refresh(valueReference, in: self)
  }
}
