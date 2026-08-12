/// The one place Cog state lives.
///
/// A declaration is a value reference — a light value naming one piece of state — and the
/// state itself is a state that lives here. A `Cogtext` stores one state per
/// descriptor and key, creates each state the first time something needs it,
/// and never creates one for a declaration nobody uses (§2.3). That split is
/// what keeps a top-level `let` cheap enough to write freely: an app may
/// declare a thousand cogs and pay for the handful it actually reads.
///
/// One running app has one context. Every feature resolves through it, which
/// is what makes state singular — no screen-local islands, no second copy of a
/// fact to keep in step — and it gives Cog one owner for the whole app's turn
/// history. Tests and previews are separate app runtimes rather than exceptions
/// to that rule: each gets its own isolated context and fragments nothing
/// inside it.
///
/// Construction is therefore guarded. The initializer below is `package`, so
/// application code cannot name it at all. The app's bootstrap calls
/// `Cogtext.bootstrapApp()` once at launch, and the `CogTesting` product vends
/// `Cogtext.forTesting()` for a fresh isolated context as often as a test or
/// preview asks. Splitting the two by product, rather than by an argument to
/// one helper, keeps the test factory out of a shipping app target entirely.
///
/// The whole graph is confined to the MainActor (§1.2, §2.5). SwiftUI reads are
/// synchronous and cannot `await`, so a graph on another actor could not serve
/// them; one execution lane also means a turn is never interleaved with
/// another. Isolation is stated explicitly here rather than inherited from the
/// module's default, so the type says the same thing to every consumer whatever
/// their own default isolation is (§7).
@MainActor
public final class Cogtext {
  /// The monotonic clock used by context-owned timing work.
  ///
  /// Production injects a ``ContinuousClock``. `CogTesting` can instead
  /// retain a clock the test controls, so grace periods and other timed work
  /// wait for a definite signal rather than wall-clock time.
  internal let clock: any Clock<Duration>

  /// Grace used when a descriptor selects the context default.
  internal let defaultWhileObservedGrace: Duration

  /// One test-only acknowledgement installed through the CogTesting product.
  private var nextLifetimeReleaseAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// The monotonic version assigned to graph work.
  ///
  /// Every outer turn advances it once at its commit boundary, including an
  /// empty or all-equal turn. A changed debug seed advances it without a turn.
  /// The settle engine compares state versions while pulling a derived root
  /// current.
  internal private(set) var revision: CogVersion = .initial

  /// One enter/exit buffer reused by iterative settle walks.
  internal var settleStack = CogSettleStack()

  /// The structural phase of the current turn, or idle between turns.
  ///
  /// This begins as the small correctness representation from §3.2. The
  /// data-oriented core later replaces it without exposing the phase as API.
  internal var turnPhase: CogTurnPhase = .idle

  /// Commits requested while a turn is flushing, in arrival order.
  ///
  /// The outer `withTurn` call drains this buffer only after its active turn
  /// returns to idle. Bodies added by a queued turn's own flush extend the same
  /// buffer, so no write-back re-enters a flush and FIFO order is preserved.
  internal var queuedTurns: [QueuedCogTurn] = []

  /// Reactions this context owns, in registration order.
  ///
  /// The simple core walks this array at the end of a flush. Invalidations
  /// leave clean reactions alone and mark only reachable ones, so an unrelated
  /// turn pays the scan but never runs user code. M6 replaces the scan with its
  /// measured flat queue without changing ordering or behavior.
  internal var reactions: [CogReaction] = []

  /// Work still to run in the active flush's reaction phase.
  ///
  /// Changed registrations are scheduled first. A registration made anywhere
  /// in the flush appends an initial run to the tail, so it cannot re-enter its
  /// caller and still completes before queued write-back turns begin.
  internal var reactionRuns: [CogReactionRun] = []

  /// Every state this context has been asked for, filed by descriptor and key.
  ///
  /// Heterogeneous on purpose: a context holds states of every value type an app
  /// declares, and nothing about storing them needs to know those types.
  /// ``CogState`` is the narrow view across them, and the concrete type comes
  /// back at the point of use, where the value reference's own `Value` names it.
  ///
  /// A dictionary is the correctness build's answer, not the final one. The
  /// data-oriented core (perf §3) replaces it with slotted storage; nothing
  /// outside this file may depend on the shape, which is why lookup goes
  /// through ``manualState(for:)`` rather than the dictionary directly.
  internal private(set) var states: [CogStateIdentity: any CogState] = [:]

  /// Whose run is capturing dependencies right now, or `nil` between runs.
  ///
  /// §2.4 puts the current consumer in a MainActor tracking slot while a
  /// selector or reaction runs, and that is what this is. One slot is enough
  /// because the graph has one execution lane (§1.2): runs nest, but they
  /// never interleave, so ``Cogtext/tracking(_:_:)`` can save and restore this
  /// like a stack frame.
  ///
  /// A stored property rather than something an extension could add, which is
  /// why the slot lives in this file with the rest of the context's state.
  internal var trackedConsumer: (any CogConsumer)?

  #if DEBUG
  /// How many graph operations currently make a quiet seed unsafe.
  ///
  /// Reader tracking covers selector and reaction bodies, but a derived
  /// declaration's equality closure runs after tracking ends and before its
  /// state is marked current. This debug-only barrier spans that whole derived
  /// run, and seed itself, so test setup cannot re-enter either operation and
  /// have a later state mark erase the seed's invalidation.
  internal var seedBarrierDepth = 0

  /// One synchronous root turn and the FIFO write-back turns it causes.
  ///
  /// The tracker warns once after a long uninterrupted drain and retains only
  /// the last structured warning for the `CogTesting` diagnostic seam.
  internal var quiescenceTracker = CogQuiescenceTracker()

  /// What this context has done lately (§2.3, perf §8).
  ///
  /// Debug builds only, so a release build carries no ring, records nothing,
  /// and compiles no recording call (`HIST-04`). This is the library's first
  /// `#if DEBUG`, and the pattern it sets is to gate the storage, the record
  /// types, the reader, and every call site together — release never has to
  /// compile around a hole.
  internal var historyLog = CogHistoryLog()
  #endif

  /// Creates an empty context.
  ///
  /// `package` rather than `public` so that the only ways to make a context
  /// from outside are the two deliberate ones: `Cogtext.bootstrapApp()` for the
  /// app, and `Cogtext.forTesting()` for a test or preview runtime. Feature
  /// code that tries to build a plain context does not get a runtime error, it
  /// gets a compile error, because the name is not visible to it.
  package init(
    clock: any Clock<Duration> = ContinuousClock(),
    defaultWhileObservedGrace: Duration = .seconds(30)
  ) {
    self.clock = clock
    self.defaultWhileObservedGrace = defaultWhileObservedGrace
  }

  /// Breaks graph-owned dependency chains before stored properties release.
  ///
  /// State dependencies are strong so a producer stays alive for as long as a
  /// live consumer needs it. Releasing a very deep context without severing
  /// those links first can make ARC recursively destroy the whole chain and
  /// exhaust the process stack. The context already owns every state, so one
  /// flat pass can drop all consumer-to-producer links before its dictionary
  /// and reaction arrays begin their ordinary teardown.
  isolated deinit {
    for state in states.values {
      (state as? any CogConsumer)?.releaseDependenciesForContextTeardown()
    }
    for reaction in reactions {
      reaction.releaseDependenciesForContextTeardown()
    }
  }
}

// MARK: - State storage

extension Cogtext {
  /// Adds one reaction-owned lease when this state uses observed lifetime.
  ///
  /// Invalidating an earlier release generation makes reacquisition safe even
  /// when its clock sleep has already begun.
  internal func acquireExternalLease(on state: any CogLifetimeLeaseState) {
    guard case .whileObserved = state.lifetime else { return }
    state.advanceLifetimeReleaseGeneration()
    state.incrementExternalLeaseCount()
  }

  /// Removes one reaction-owned lease when this state uses observed lifetime.
  ///
  /// Context teardown bypasses this normal path because no release work should
  /// be scheduled while the whole graph is already being destroyed.
  internal func releaseExternalLease(on state: any CogLifetimeLeaseState) {
    guard case .whileObserved(let declaredGrace) = state.lifetime else { return }
    state.decrementExternalLeaseCount()
    guard state.externalLeaseCount == 0 else { return }

    let generation = state.advanceLifetimeReleaseGeneration()
    let identity = state.stateIdentity
    let grace = declaredGrace ?? defaultWhileObservedGrace
    let clock = clock

    Task { @MainActor [weak self, weak state] in
      do {
        try await clock.sleep(for: grace)
      } catch {
        return
      }

      guard let self, let state else { return }
      self.releaseDerivedStateIfEligible(
        state,
        identity: identity,
        generation: generation
      )
    }
  }

  /// Installs a one-shot behavior acknowledgement for a lifetime scenario.
  package func acknowledgeNextDerivedRelease(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextLifetimeReleaseAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next derived release.")
    }
    nextLifetimeReleaseAcknowledgement = acknowledgement
  }

  /// Removes the exact still-unobserved state after its grace task resumes.
  private func releaseDerivedStateIfEligible(
    _ state: any CogLifetimeLeaseState,
    identity: CogStateIdentity,
    generation: UInt64
  ) {
    guard let stored = states[identity], stored === state else { return }
    guard state.lifetimeReleaseGeneration == generation else { return }
    guard state.externalLeaseCount == 0 else { return }
    guard case .whileObserved = state.lifetime else { return }

    // A still-live internal consumer needs this exact producer until the later
    // closure-release slice can collect the whole unobserved dependency graph.
    guard state.subscribers.isEmpty else { return }

    states.removeValue(forKey: identity)
    state.releaseDependenciesForLifetime()

    let acknowledgement = nextLifetimeReleaseAcknowledgement
    nextLifetimeReleaseAcknowledgement = nil
    acknowledgement?()
  }

  /// Advances the graph revision for one turn flush or changed debug seed.
  @discardableResult
  internal func advanceRevision() -> CogVersion {
    revision = revision.advanced()
    return revision
  }

  /// The state this value reference names in this context, created if this is its first use.
  ///
  /// Lazy creation is not a memory optimization bolted onto declarations; it is
  /// what a declaration means. A `ManualCog` is a name, and a name costs
  /// nothing until something asks this context to resolve it. It is also what
  /// lets a keyed box be declared once and used for any number of keys: the key
  /// is half of the storage identity, so `box[90210]` and `box[10001]` resolve
  /// to two states of the same declaration.
  internal func manualState<Value>(for valueReference: ManualCog<Value>) -> ManualCogState<Value> {
    state(CogStateIdentity(descriptor: valueReference.descriptor.identity, key: valueReference.key))
    {
      ManualCogState(descriptor: valueReference.descriptor, key: valueReference.key)
    }
  }

  /// The state this derived value reference names in this context, created if this is its
  /// first use.
  ///
  /// Creating a derived state still computes nothing: the state arrives without a
  /// value and runs its selector when something first reads it (§2.2). The
  /// filing rule is the same one manual sources use, which is the point — a
  /// derived cog is another declaration with another kind of state behind it,
  /// not another kind of storage.
  internal func derivedState<Value>(for valueReference: Cog<Value>) -> DerivedCogState<Value> {
    state(CogStateIdentity(descriptor: valueReference.descriptor.identity, key: valueReference.key))
    {
      DerivedCogState(descriptor: valueReference.descriptor, key: valueReference.key)
    }
  }

  /// Finds the state filed under `identity`, filing what `create` makes if there
  /// is none.
  ///
  /// The cast back to a concrete state type cannot fail in a correct build. The
  /// identity contains the descriptor, the descriptor is generic over the
  /// value, and only this method ever files a state — so a hit means a state
  /// built from this very descriptor, by the one value-reference kind that owns that
  /// descriptor kind. The check stays anyway, and fails loudly rather than
  /// silently reinterpreting memory, because it is the kind of invariant a
  /// future storage change could break quietly.
  private func state<State: CogState>(
    _ identity: CogStateIdentity,
    create: () -> State
  ) -> State {
    if let existing = states[identity] {
      guard let state = existing as? State else {
        // `fatalError`, not `preconditionFailure`: this message is composed,
        // and an optimized `preconditionFailure` drops composed messages, so
        // a release crash here would say nothing at all.
        fatalError(
          """
          The state for \(existing.label) is a \(type(of: existing)), not a \
          \(State.self). Two declarations cannot share one descriptor identity, \
          so this context's state storage is corrupt.
          """
        )
      }
      return state
    }

    let created = create()
    states[identity] = created
    return created
  }
}

// MARK: - Reading

extension Cogtext {
  /// Reads a source's current value without creating a dependency edge.
  ///
  /// This is the one-shot untracked read (§2.4): the spelling for an op, a
  /// test, or any other place outside a selector that needs a value once and is
  /// not going to be rerun when it changes. Inside a selector, use the tracked
  /// read on the controller instead — an untracked read that should have been
  /// tracked is a stale-value bug, so keep this one rare and deliberate.
  ///
  /// Untracked never means stale. The rule is that skipping the edge skips only
  /// the subscription: the value handed back is still the settled value of the
  /// latest completed turn. A manual source satisfies that for free, because
  /// nothing computes it — there is no work that could be outstanding. The
  /// derived read below is where that promise takes work.
  ///
  /// - Parameter valueReference: The source to read.
  /// - Returns: The value the source holds in this context, which is its
  ///   declaration's starting value until a turn writes it.
  public func read<Value>(_ valueReference: ManualCog<Value>) -> Value {
    manualState(for: valueReference).currentValue
  }

  /// Reads a derived cog's value without creating a dependency edge.
  ///
  /// The same one-shot untracked read as the one for a source (§2.4), and the
  /// spelling a test, an op, or any other code outside a selector uses to look
  /// at a computed value once. Inside a selector, use `c.get` instead, so the
  /// selector reruns when this value changes.
  ///
  /// A derived value can be outstanding work rather than a stored fact, so this
  /// read is where laziness becomes visible: if nothing has ever read this cog
  /// in this context, reading it here runs its selector, and running it reads
  /// whatever *it* depends on, down as far as the first read has to go. What
  /// comes back is a value, never a promise of one.
  ///
  /// Computing is not the same as settling. This path also brings a cog that a
  /// later turn dirtied back up to date before returning, so that skipping the
  /// edge never means seeing a stale value. That step belongs here, in the one
  /// read path every caller shares, rather than at call sites where a caller
  /// could spell a read that skips it.
  ///
  /// - Parameter valueReference: The derived cog to read.
  /// - Returns: Its value in this context.
  public func read<Value>(_ valueReference: Cog<Value>) -> Value {
    derivedState(for: valueReference).settledValue(in: self)
  }
}
