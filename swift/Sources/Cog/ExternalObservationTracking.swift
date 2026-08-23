internal import Observation

/// Which runtime path links external Observation state into one context.
///
/// Production selects automatically from OS availability. `CogTesting` may
/// force the legacy path on a newer host so its bounded compatibility behavior
/// and deterministic re-arm seam remain testable after CI moves past iOS 25.
package enum CogExternalObservationTrackingMode: Sendable {
  /// Use continuous Observation where available and the legacy shim otherwise.
  case automatic

  /// Use the pre-iOS-26 one-shot re-arm shim regardless of host availability.
  case legacy
}

/// The selector consumer that owns one closure-form external observation.
///
/// A call-site identity alone would collide when a shared selector helper runs
/// for several keyed states. The exact generation-checked arena slot supplies
/// the missing per-consumer namespace.
internal nonisolated enum CogExternalObservationConsumerIdentity: Hashable {
  /// One exact lifetime of an arena selector row.
  case arena(CogArenaSlot)
}

/// The context-local identity of one linked external read.
///
/// Key paths share one observer across every consumer reading the same property.
/// Closure forms belong to one selector and source call site because their
/// captured inputs may change independently on each selector run.
internal nonisolated enum CogExternalObservationIdentity: Hashable {
  /// One exact property on one exact external model.
  case keyPath(object: ObjectIdentifier, keyPath: AnyKeyPath)

  /// One closure expression in one selector consumer.
  case closure(
    consumer: CogExternalObservationConsumerIdentity,
    fileID: String,
    line: UInt,
    column: UInt
  )
}

/// Type-erased cancellation owned by one ``Cogs`` context.
///
/// A context retains every bridge it has created so Observation remains armed
/// after the selector that first called `track` returns. Context teardown
/// cancels the task before graph state and the external model are released.
@MainActor
internal protocol CogExternalObservationBridge: AnyObject {
  /// Stops future external publications and releases the task capture.
  func cancel()
}

/// A one-shot legacy Observation registration that re-arms after each change.
///
/// `withObservationTracking` calls `onChange` from `willSet` and consumes the
/// registration before doing so. The sendable callback therefore performs no
/// graph work itself. It enqueues a MainActor task, allowing the setter to
/// finish, and that task installs the next registration before it reads and
/// publishes the newest value. Mutations in the small interval between the
/// callback and that re-arm can be missed; the public contract names that
/// legacy limitation instead of promising continuous tracking.
@MainActor
internal final class CogLegacyObservationShim<Value> {
  /// Reads the exact external property while Observation records accesses.
  private let read: @MainActor () -> Value

  /// Receives the newest value after the setter and re-arm both finish.
  private let didChange: @MainActor (Value) -> Void

  /// Internal seam fired after each post-change registration is installed.
  private let didRearm: @MainActor () -> Void

  /// Whether this one-shot-lifetime observer has ever installed tracking.
  private var hasStarted = false

  /// Whether callbacks may enqueue another observation transition.
  private var isStarted = false

  /// Creates an idle shim around one property read.
  ///
  /// - Parameters:
  ///   - read: The synchronous MainActor property access to observe.
  ///   - didChange: Publication after the setter completes and tracking re-arms.
  ///   - didRearm: Test seam acknowledging the completed re-arm transition.
  init(
    read: @escaping @MainActor () -> Value,
    didChange: @escaping @MainActor (Value) -> Void,
    didRearm: @escaping @MainActor () -> Void = {}
  ) {
    self.read = read
    self.didChange = didChange
    self.didRearm = didRearm
  }

  /// Installs the initial one-shot registration synchronously.
  func start() {
    guard !hasStarted else {
      fatalError("A legacy Cog external-property observer started twice.")
    }
    hasStarted = true
    isStarted = true
    _ = arm()
  }

  /// Prevents a fired or future callback from publishing another transition.
  func cancel() {
    isStarted = false
  }

  /// Reads the current value and registers the callback consumed by its change.
  private func arm() -> Value {
    withObservationTracking {
      read()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.consumeChange()
      }
    }
  }

  /// Re-arms before publishing the value read after the completed setter.
  private func consumeChange() {
    guard isStarted else { return }
    let value = arm()
    didRearm()
    didChange(value)
  }

  // Written explicitly for the generic-class release-build rule. Cancellation
  // needs no isolation because queued callbacks hold this shim only weakly.
  nonisolated deinit {}
}

/// One runtime-appropriate Observation read feeding one hidden Cog source.
///
/// The source is an implementation detail: selectors record an ordinary graph
/// edge to it, so the arena reuses its existing invalidation, settlement,
/// equality, and turn machinery. The bridge stays MainActor-bound
/// with the external model and never sends its possibly non-Sendable value
/// across an isolation boundary.
@MainActor
internal final class CogTrackedValueBridge<Tracked>: CogExternalObservationBridge {
  /// Read performed while Observation records its exact property accesses.
  private var read: @MainActor () -> Tracked

  /// Hidden source on which dependent Cog selectors record their edge.
  let sourceCog: Cog<Tracked>.Manual

  /// Stable diagnostic name used by every hidden-source publication.
  private let turnName: String

  /// Continuous modern observation, or `nil` on a pre-iOS-26 runtime.
  private var observationTask: Task<Void, Never>?

  /// One-shot legacy observer, or `nil` on a 26-era runtime.
  private var legacyObservation: CogLegacyObservationShim<Tracked>?

  /// Creates the hidden source at the same value used to arm Observation.
  init(
    read: @escaping @MainActor () -> Tracked,
    initialValue: Tracked,
    turnName: String
  ) {
    self.read = read
    self.sourceCog = Cog.Manual(initialValue, name: "c.track")
    self.turnName = turnName
  }

  /// Arms the runtime-appropriate external observation path.
  ///
  /// M7-13a owns the iOS 26 path. M7-14a fills the older-runtime branch with
  /// its explicitly bounded one-shot re-arm shim.
  func start(in cogs: Cogs) {
    guard observationTask == nil, legacyObservation == nil else {
      fatalError("A Cog external-property bridge started twice.")
    }
    if cogs.externalObservationTrackingMode == .legacy {
      startLegacyObservation(in: cogs)
    } else {
      if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) {
        startModernObservation(in: cogs)
      } else {
        startLegacyObservation(in: cogs)
      }
    }
  }

  /// Starts synchronously through the first `Observations` suspension.
  ///
  /// `Task.immediate` is correctness-critical here: the first iteration reads
  /// the property and arms Observation before the selector that called
  /// `track` can return to application code. That first value already seeded
  /// the hidden source, so it is skipped. Later iterations occur only after a
  /// mutation transaction reaches its actor suspension boundary; reading the
  /// property there therefore captures the newest post-setter value.
  @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
  private func startModernObservation(in cogs: Cogs) {
    let read = read
    let sourceCog = sourceCog
    let turnName = turnName
    observationTask = Task.immediate(name: turnName) { @MainActor [weak cogs] in
      let changes = Observations {
        _ = read()
      }
      var isInitialValue = true
      for await _ in changes {
        guard !Task.isCancelled else { return }
        if isInitialValue {
          isInitialValue = false
          continue
        }
        guard let cogs else { return }
        let value = read()
        cogs.turn(turnName) { c in c[sourceCog] = value }
      }
    }
  }

  /// Starts the one-shot observer used before the continuous runtime API.
  ///
  /// The shim owns deferral past `willSet` and re-arm ordering. This bridge
  /// converts each accepted newest value into an ordinary hidden-source turn.
  private func startLegacyObservation(in cogs: Cogs) {
    let read = read
    let sourceCog = sourceCog
    let turnName = turnName
    let observation = CogLegacyObservationShim(
      read: read,
      didChange: { [weak cogs] value in
        guard let cogs else { return }
        cogs.turn(turnName) { c in c[sourceCog] = value }
        cogs.acknowledgeExternalObservationRearmIfRequested()
      }
    )
    legacyObservation = observation
    observation.start()
  }

  /// Replaces a closure-form read while preserving its one hidden source.
  ///
  /// A selector rerun may capture different ordinary inputs. Cancelling and
  /// synchronously re-arming makes Observation follow the new read set before
  /// the selector returns. The direct value is returned because the hidden
  /// source exists to carry invalidation; it may still hold the preceding
  /// closure result until the next external boundary publishes.
  func replaceRead(
    _ read: @escaping @MainActor () -> Tracked,
    in cogs: Cogs
  ) -> Tracked {
    stopObserving()
    self.read = read
    let currentValue = read()
    start(in: cogs)
    return currentValue
  }

  /// Cancels the exact modern task or legacy registration this bridge owns.
  func cancel() {
    stopObserving()
  }

  /// Stops either runtime path without releasing the hidden source or read.
  private func stopObserving() {
    observationTask?.cancel()
    observationTask = nil
    legacyObservation?.cancel()
    legacyObservation = nil
  }

  // Written explicitly for the generic-class release-build rule. The owning
  // context calls `cancel()` from its isolated deinitializer before release.
  nonisolated deinit {}
}

extension Cogs {
  /// Resolves or creates the hidden source for one external property.
  ///
  /// Insertion precedes immediate observation startup so a synchronously armed
  /// bridge is already context-owned. Repeated selector runs recover the same
  /// typed bridge and therefore add no observer or state island.
  internal func trackedPropertySource<Root: Observable & AnyObject, Tracked>(
    for root: Root,
    keyPath: KeyPath<Root, Tracked>
  ) -> Cog<Tracked>.Manual {
    let identity = CogExternalObservationIdentity.keyPath(
      object: ObjectIdentifier(root),
      keyPath: keyPath
    )
    if let existing = externalObservationBridges[identity] {
      guard let bridge = existing as? CogTrackedValueBridge<Tracked> else {
        fatalError(
          "A c.track bridge was recovered with an incompatible model or property type."
        )
      }
      return bridge.sourceCog
    }

    let bridge = CogTrackedValueBridge(
      read: { root[keyPath: keyPath] },
      initialValue: root[keyPath: keyPath],
      turnName: "c.track(\(keyPath))"
    )
    externalObservationBridges[identity] = bridge
    bridge.start(in: self)
    return bridge.sourceCog
  }

  /// Resolves and re-arms one selector-owned closure-form external read.
  ///
  /// The bridge and hidden source remain singular across selector reruns. The
  /// current closure replaces the prior capture and re-arms synchronously, so a
  /// changing captured index or branch cannot leave Observation attached to an
  /// earlier read set.
  internal func trackedClosureSource<Tracked>(
    for consumer: CogExternalObservationConsumerIdentity,
    fileID: String,
    line: UInt,
    column: UInt,
    read: @escaping @MainActor () -> Tracked
  ) -> (sourceCog: Cog<Tracked>.Manual, value: Tracked) {
    let identity = CogExternalObservationIdentity.closure(
      consumer: consumer,
      fileID: fileID,
      line: line,
      column: column
    )
    if let existing = externalObservationBridges[identity] {
      guard let bridge = existing as? CogTrackedValueBridge<Tracked> else {
        fatalError("A c.track closure bridge was recovered with an incompatible value type.")
      }
      let value = bridge.replaceRead(read, in: self)
      return (bridge.sourceCog, value)
    }

    let initialValue = read()
    let bridge = CogTrackedValueBridge(
      read: read,
      initialValue: initialValue,
      turnName: "c.track closure at \(fileID):\(line):\(column)"
    )
    externalObservationBridges[identity] = bridge
    bridge.start(in: self)
    return (bridge.sourceCog, initialValue)
  }
}
