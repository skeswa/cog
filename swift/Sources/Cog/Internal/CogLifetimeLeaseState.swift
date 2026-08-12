/// A derived state whose context may release it when no external consumer holds it.
///
/// Reactions lease the derived roots they read. Internal dependency edges do
/// not count as external observation.
@MainActor
internal protocol CogLifetimeLeaseState: CogState {
  /// The declaration policy that decides whether external leases apply.
  var lifetime: CogStateLifetime { get }

  /// How many external consumers currently keep this state observed.
  var externalLeaseCount: Int { get set }

  /// The dictionary identity the context must still map to this exact state.
  var stateIdentity: CogStateIdentity { get }

  /// Invalidates stale grace completions when observation changes.
  var lifetimeReleaseGeneration: UInt64 { get set }

  /// Severs this state's forward and reverse dependency edges before removal.
  func releaseDependenciesForLifetime()
}

extension CogLifetimeLeaseState {
  /// Adds one external owner without silently wrapping the count.
  func incrementExternalLeaseCount() {
    guard externalLeaseCount < Int.max else {
      fatalError("A Cog state's external lifetime lease count overflowed.")
    }
    externalLeaseCount += 1
  }

  /// Removes one external owner without hiding an ownership imbalance.
  func decrementExternalLeaseCount() {
    guard externalLeaseCount > 0 else {
      fatalError("A Cog state's external lifetime lease count underflowed.")
    }
    externalLeaseCount -= 1
  }

  /// Advances the generation without permitting wraparound to revive a stale task.
  @discardableResult
  func advanceLifetimeReleaseGeneration() -> UInt64 {
    guard lifetimeReleaseGeneration < UInt64.max else {
      fatalError("A Cog state's lifetime release generation overflowed.")
    }
    lifetimeReleaseGeneration += 1
    return lifetimeReleaseGeneration
  }
}
