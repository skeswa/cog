internal import Observation

/// The context-local identity of one linked external property.
///
/// Object identity keeps equal-valued models separate. Key-path equality keeps
/// repeated reads of the same property on one model attached to one bridge,
/// while sibling properties receive independent Observation registrations.
internal nonisolated struct CogExternalObservationIdentity: Hashable {
  /// The exact external model instance.
  let object: ObjectIdentifier

  /// The exact property selected on that model.
  let keyPath: AnyKeyPath
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

/// One iOS 26 Observation sequence feeding one hidden Cog source.
///
/// The source is an implementation detail: selectors record an ordinary graph
/// edge to it, so both storage cores reuse their existing invalidation,
/// settlement, equality, and turn machinery. The bridge stays MainActor-bound
/// with the external model and never sends its possibly non-Sendable value
/// across an isolation boundary.
@MainActor
internal final class CogTrackedPropertyBridge<Root: Observable & AnyObject, Tracked>:
  CogExternalObservationBridge
{
  /// Model retained for as long as this context tracks its property.
  let root: Root

  /// Property read by both Observation and each post-boundary publication.
  let keyPath: KeyPath<Root, Tracked>

  /// Hidden source on which dependent Cog selectors record their edge.
  let sourceCog: ManualCog<Tracked>

  /// Continuous modern observation, or `nil` on a pre-iOS-26 runtime.
  private var observationTask: Task<Void, Never>?

  /// Creates the hidden source at the same value used to arm Observation.
  init(root: Root, keyPath: KeyPath<Root, Tracked>, initialValue: Tracked) {
    self.root = root
    self.keyPath = keyPath
    self.sourceCog = ManualCog(initialValue, name: "c.track")
  }

  /// Arms the runtime-appropriate external observation path.
  ///
  /// M7-13a owns the iOS 26 path. M7-14a fills the older-runtime branch with
  /// its explicitly bounded one-shot re-arm shim.
  func start(in cogs: Cogs) {
    guard observationTask == nil else {
      fatalError("A Cog external-property bridge started twice.")
    }
    if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) {
      startModernObservation(in: cogs)
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
    let root = root
    let keyPath = keyPath
    let sourceCog = sourceCog
    let turnName = "c.track(\(keyPath))"
    observationTask = Task.immediate(name: turnName) { @MainActor [weak cogs] in
      let changes = Observations {
        _ = root[keyPath: keyPath]
      }
      var isInitialValue = true
      for await _ in changes {
        guard !Task.isCancelled else { return }
        if isInitialValue {
          isInitialValue = false
          continue
        }
        guard let cogs else { return }
        let value = root[keyPath: keyPath]
        cogs.commit(turnName) { c in c[sourceCog] = value }
      }
    }
  }

  /// Cancels the exact observation task this bridge owns.
  func cancel() {
    observationTask?.cancel()
    observationTask = nil
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
  ) -> ManualCog<Tracked> {
    let identity = CogExternalObservationIdentity(
      object: ObjectIdentifier(root),
      keyPath: keyPath
    )
    if let existing = externalObservationBridges[identity] {
      guard let bridge = existing as? CogTrackedPropertyBridge<Root, Tracked> else {
        fatalError(
          "A c.track bridge was recovered with an incompatible model or property type."
        )
      }
      return bridge.sourceCog
    }

    let bridge = CogTrackedPropertyBridge(
      root: root,
      keyPath: keyPath,
      initialValue: root[keyPath: keyPath]
    )
    externalObservationBridges[identity] = bridge
    bridge.start(in: self)
    return bridge.sourceCog
  }
}
