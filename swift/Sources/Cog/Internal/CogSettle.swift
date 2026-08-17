/// One monotonic graph revision in the simple correctness core.
///
/// `changedAt` records the last value change. `checkedAt` records the last
/// revision proved current, including an equal recomputation. Their difference
/// lets an equal middle state stop downstream work (§2.4, perf §3.4).
///
/// The class-state core uses a wide scalar and leaves the compact integer
/// layout to M6's measured arena. The type itself is nonisolated because a
/// revision is inert data even though the context that advances it is not.
internal nonisolated struct CogVersion: Comparable, Sendable {
  /// Before any turn has advanced the graph.
  static let initial = CogVersion(rawValue: 0)

  private let rawValue: UInt64

  /// Orders revisions by their monotonically increasing scalar.
  static func < (lhs: CogVersion, rhs: CogVersion) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// The next revision. Wraparound traps before old values appear current.
  func advanced() -> CogVersion {
    guard rawValue < UInt64.max else {
      fatalError("Cog exhausted its graph revision counter.")
    }
    return CogVersion(rawValue: rawValue + 1)
  }
}

/// How much work a state is known to need before its value may be returned.
///
/// The order is a strength lattice used by push propagation:
///
/// - `clean`: the cached value is current;
/// - `check`: something upstream may have changed, so settle parents and
///   compare their versions;
/// - `dirty`: a direct dependency changed, so the state must recompute after
///   its parents settle.
///
/// A weaker invalidation never replaces a stronger one. In particular, a
/// transitive CHECK path cannot erase a direct DIRTY path in a diamond.
internal enum CogSettleState: UInt8, Comparable {
  /// The cached value is current through `checkedAt`.
  case clean
  /// Settle dependencies and recompute only if one changed after `checkedAt`.
  case check
  /// A direct input changed, so recomputation is mandatory after parents settle.
  case dirty

  /// Orders marks by strength so propagation never replaces DIRTY with CHECK.
  static func < (lhs: CogSettleState, rhs: CogSettleState) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// One weak reverse edge in the class-state correctness core.
///
/// A derived state strongly owns the producers in its dependency list. Keeping
/// the reverse edge weak prevents those two arrays from forming a retain cycle
/// when a context or, later, a released state lets the graph go.
internal final class CogSubscriberEdge {
  /// The consumer to invalidate, or `nil` after it has been released.
  weak var state: (any CogState)?

  /// Creates a non-owning reverse edge to `state`.
  init(_ state: any CogState) {
    self.state = state
  }
}

extension CogState {
  /// Adds one reverse edge, reusing the existing edge when a stable selector
  /// reads the same producer again.
  ///
  /// Dead weak edges are pruned before identity comparison. Dependency arrays
  /// may preserve repeated reads, but invalidation visits a consumer only once
  /// per producer.
  func addSubscriber(_ consumer: any CogState) {
    subscribers.removeAll { $0.state == nil }
    guard !subscribers.contains(where: { $0.state === consumer }) else { return }
    subscribers.append(CogSubscriberEdge(consumer))
  }

  /// Removes the reverse edge for a consumer that did not read this producer
  /// on its latest run, while also pruning subscribers that have gone away.
  func removeSubscriber(_ consumer: any CogState) {
    subscribers.removeAll { edge in
      guard let subscriber = edge.state else { return true }
      return subscriber === consumer
    }
  }

  /// Records possible upstream work without weakening an existing DIRTY mark.
  func markForCheck() {
    if settleState < .check {
      settleState = .check
    }
  }

  /// Records that a direct dependency changed and recomputation is required.
  func markDirty() {
    settleState = .dirty
  }

  /// Records that the state was checked through `version` and stayed equal.
  ///
  /// Preserve `changedAt`; downstream CHECK consumers compare it with their own
  /// earlier `checkedAt` to decide that no rerun is needed.
  func markChecked(at version: CogVersion) {
    checkedAt = version
    settleState = .clean
  }

  /// Records that the state's current value changed in `version`.
  ///
  /// Publishing a value proves it current too, so both timestamps advance and
  /// the state returns to CLEAN before subscribers are invalidated.
  func markChanged(at version: CogVersion) {
    changedAt = version
    checkedAt = version
    settleState = .clean
  }
}

/// The type-erased capabilities only a derived state needs during settlement.
///
/// This protocol lets an erased exit frame inspect dependencies and rerun a
/// generic selector. Its state remains on the ordered computing path from enter
/// until exit completes, including nested pulls and user equality code.
@MainActor
internal protocol DerivedCogSettleState: CogState {
  /// The declaration half of this state's stable descriptor-and-key identity.
  var descriptorIdentity: ObjectIdentifier { get }

  /// The key half of this state's identity, or `nil` for a keyless declaration.
  var key: CogKey? { get }

  /// Whether this state is on the context's active derived-computation path.
  var isComputing: Bool { get set }

  /// Producers captured by the latest completed synchronous selector run.
  var dependencies: [any CogState] { get }

  /// Recomputes after dirty parents are current, while this state is computing.
  func recompute(in cogs: Cogs)
}

/// One frame in the iterative pull walk.
///
/// Enter frames schedule dependencies. Exit frames compare versions and
/// recompute after those dependencies settle. Type erasure avoids recursive
/// generic calls.
internal enum CogSettleFrame {
  /// Inspect a state and schedule its dirty producers before its exit.
  case enter(any CogState)
  /// Decide whether the now-parent-current state must recompute.
  case exit(any CogState)
}

/// The context-owned traversal storage reused by every settle walk.
///
/// Nested pulls append above a checkpoint and pop their own suffix. They share
/// the active computation path for cycle detection. The arena core will replace
/// references with slots but keep this traversal shape. Frames and computing
/// states are separate intentionally: after an exit frame is popped, its state
/// remains computing through recomputation, and a nested settle may temporarily
/// consume every frame while that enclosing computation is still active.
internal struct CogSettleStack {
  private var frames: [CogSettleFrame] = []
  private var computingPath: [any DerivedCogSettleState] = []

  /// Number of pending enter and exit frames across all nested settle walks.
  var count: Int { frames.count }
  /// Reserved frame storage exposed only to infrastructure diagnostics.
  var capacity: Int { frames.capacity }
  /// Whether no traversal frame remains; this does not imply no computation is active.
  var isEmpty: Bool { frames.isEmpty }
  /// Number of derived states on the active synchronous computation path.
  var computingCount: Int { computingPath.count }
  /// Whether selectors and their post-tracking equality/publication work have unwound.
  var isComputingEmpty: Bool { computingPath.isEmpty }

  /// The innermost cog whose derived computation has not published yet.
  ///
  /// Used by commit rejection. Ordinary reads use the per-state Boolean.
  var innermostComputingState: (any DerivedCogSettleState)? {
    computingPath.last
  }

  /// Resets only the raw frame buffer for low-level stack infrastructure tests.
  /// Production settlement uses checkpoints so a nested pull preserves its
  /// caller's pending frames and active computation path.
  mutating func reset(startingAt root: any CogState) {
    frames.removeAll(keepingCapacity: true)
    frames.append(.enter(root))
  }

  /// Appends an enter frame above the current nested-walk checkpoint.
  mutating func pushEnter(_ state: any CogState) {
    frames.append(.enter(state))
  }

  /// Appends an exit frame that runs after the state's scheduled dependencies.
  mutating func pushExit(_ state: any CogState) {
    frames.append(.exit(state))
  }

  /// Removes the next LIFO traversal frame, or `nil` when the buffer is empty.
  mutating func popLast() -> CogSettleFrame? {
    frames.popLast()
  }

  /// The innermost `count` steps of the active computation path, outermost
  /// first, rendered for a diagnostic.
  ///
  /// The cold-nesting guard names the chain it stopped in, the way the cycle
  /// diagnostic names the loop it found. Only the innermost slice: a chain long
  /// enough to trip the bound is too long to print, and its tail is the part
  /// that shows the caller which declarations are stacked.
  func innermostComputingNames(_ count: Int) -> [String] {
    computingPath.suffix(count).map { state in
      guard let key = state.key else { return "\(state.label)" }
      return "\(state.label)[\(key.erased.base)]"
    }
  }

  /// The cycle that entering `state` would close, or `nil` for a new path step.
  ///
  /// The common path checks one Boolean. A detected cycle scans and copies the
  /// active suffix.
  func cyclePath(ifEntering state: any DerivedCogSettleState) -> CogCyclePath? {
    guard state.isComputing else { return nil }
    guard let first = computingPath.firstIndex(where: { $0 === state }) else {
      fatalError("A derived Cog was marked computing without an active path entry.")
    }

    return CogCyclePath(states: Array(computingPath[first...]) + [state])
  }

  /// Marks and appends one derived state after cycle detection has succeeded.
  ///
  /// The state bit is set before frames for its parents run, making a nested read
  /// of this state detect the cycle even if the raw frame suffix changes.
  mutating func beginComputing(_ state: any DerivedCogSettleState) {
    guard cyclePath(ifEntering: state) == nil else {
      fatalError("Cog tried to enter a derived cycle without reporting it.")
    }
    state.isComputing = true
    computingPath.append(state)
  }

  /// Clears the last derived path entry, enforcing balanced LIFO traversal.
  ///
  /// Exit is deferred around recomputation so every successful nested traversal
  /// restores both the state bit and ordered path together.
  mutating func endComputing(_ state: any DerivedCogSettleState) {
    guard let active = computingPath.last, active === state else {
      fatalError("Cog tried to finish derived computation out of path order.")
    }
    computingPath.removeLast()
    state.isComputing = false
  }
}

extension Cogs {
  /// Pushes invalidation from a changed state to its consumers.
  ///
  /// Direct consumers become DIRTY because one of their own inputs changed.
  /// States farther downstream become CHECK because equality may stop the wave
  /// before it reaches them. The local work list keeps even a deep subscriber
  /// chain off the Swift call stack.
  /// Weak edges that have lost their consumers are ignored. A state already at
  /// least as strongly marked also cuts off that traversal branch, which both
  /// preserves DIRTY and bounds diamond propagation.
  internal func invalidateSubscribers(of producer: any CogState) {
    var work: [(any CogState, CogSettleState)] = []
    for edge in producer.subscribers {
      if let subscriber = edge.state {
        work.append((subscriber, .dirty))
      }
    }

    while let (state, requestedState) = work.popLast() {
      guard state.settleState < requestedState else { continue }

      state.settleState = requestedState
      for edge in state.subscribers {
        if let subscriber = edge.state {
          work.append((subscriber, .check))
        }
      }
    }
  }

  /// Pulls one cached derived root current through iterative enter/exit frames.
  ///
  /// Enter schedules dirty parents before their consumer. Exit then uses
  /// `changedAt` versus the consumer's prior `checkedAt` to decide whether a
  /// CHECK state must run. A recomputation that lands equal advances only
  /// `checkedAt`, so consumers farther down a CHECK wave stay cached.
  ///
  /// The deferred queue drain runs after this invocation has popped its suffix.
  /// `canRunSystemTurnImmediately` also requires the shared computing path and
  /// tracking slot to be empty, preventing a nested settle from draining an
  /// async system turn while an enclosing selector is still computing.
  internal func settle(_ root: any DerivedCogSettleState) {
    defer { drainQueuedTurnsIfPossible() }

    // Cold first reads are the one settle path that cannot be flattened. A
    // state's dependency set is known only after its selector has run, so the
    // enter frame of a never-computed state has no parents to schedule; its
    // selector runs, reads an uncomputed dependency, and that read starts a
    // whole new walk inside this one. Warm re-settlement never does this,
    // because the parents are already known and scheduled iteratively.
    //
    // The nesting is therefore bounded by the Swift stack rather than by the
    // frame buffer, and the failure it produces is a stack smash with no
    // usable backtrace. Counting the walks and trapping first turns that into
    // a diagnosis (GRAPH-14).
    settleDepth += 1
    defer { settleDepth -= 1 }
    if settleDepth > Self.maximumSettleDepth {
      // `fatalError`, not `preconditionFailure`: the message is composed, and
      // an optimized build drops composed `preconditionFailure` messages.
      fatalError(coldSettleDepthMessage())
    }

    // A nested pull appends above this checkpoint and pops only its own frames.
    let boundary = settleStack.count
    settleStack.pushEnter(root)

    while settleStack.count > boundary, let frame = settleStack.popLast() {
      switch frame {
      case .enter(let state):
        guard state.settleState != .clean else { continue }
        guard let derived = state as? any DerivedCogSettleState else {
          // Sources are settled when their pending value moves to current, so
          // an invalid source here would be an internal propagation mistake.
          state.markChecked(at: revision)
          continue
        }

        if let cycle = settleStack.cyclePath(ifEntering: derived) {
          fatalError(cycle.message)
        }

        settleStack.beginComputing(derived)
        settleStack.pushExit(derived)
        for dependency in derived.dependencies.reversed()
        where dependency.settleState != .clean {
          settleStack.pushEnter(dependency)
        }

      case .exit(let state):
        guard let derived = state as? any DerivedCogSettleState else { continue }
        defer { settleStack.endComputing(derived) }

        let parentChanged = derived.dependencies.contains {
          $0.changedAt > derived.checkedAt
        }

        if derived.settleState == .dirty || parentChanged {
          derived.recompute(in: self)
        } else {
          derived.markChecked(at: revision)
        }
      }
    }
  }
}

extension Cogs {
  /// How many settle walks may nest before Cog stops and explains itself.
  ///
  /// Fixed rather than derived from the remaining stack, so one graph fails the
  /// same way everywhere. The real ceilings measured on 2026-08-16 vary by an
  /// order of magnitude — roughly 6,100 cold links in release on an 8 MiB macOS
  /// main stack, but roughly 770 in release and 240 in debug on iOS's 1 MiB —
  /// and a bound that moved with them would let a graph pass in the simulator
  /// and crash on a phone. This sits below the smallest of them with room to
  /// spare, and far above any chain of never-read cogs a screen plausibly
  /// builds.
  internal static let maximumSettleDepth = 128

  /// What Cog says when a first read nests further than it will follow.
  ///
  /// Names the innermost declarations so the caller can see which chain
  /// stacked, and says the two things that actually resolve it: read from the
  /// source end, or shorten the chain.
  private func coldSettleDepthMessage() -> String {
    let innermost = settleStack.innermostComputingNames(8)
    let chain = innermost.joined(separator: " -> ")
    return """
      Reading a Cog needed \(settleDepth) nested computations, past the limit \
      of \(Self.maximumSettleDepth). Cog computes a derived cog the first time \
      something reads it, and a first computation that reads a cog which has \
      never been computed has to compute that one inline — so reading the far \
      end of a long chain of never-read cogs nests one computation per link \
      and would exhaust the stack. The innermost links were: \(chain). Read \
      the chain from its source end first, so each link is already computed \
      when the next one reads it, or make the chain shorter. Cogs that have \
      been computed once never nest again: later changes settle iteratively, \
      however deep the graph is.
      """
  }
}
