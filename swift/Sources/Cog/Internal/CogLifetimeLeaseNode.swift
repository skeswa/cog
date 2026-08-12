/// A derived node whose context may release it when no external consumer holds it.
///
/// External leases are deliberately separate from dependency edges. A reaction
/// reading a derived root leases that root, while the root's own dependencies
/// remain ordinary graph edges. The later release engine can therefore keep the
/// reachable path correct without mistaking every internal edge for a watcher.
@MainActor
internal protocol CogLifetimeLeaseNode: CogNode {
  /// The declaration policy that decides whether external leases apply.
  var lifetime: CogNodeLifetime { get }

  /// How many external consumers currently keep this node observed.
  var externalLeaseCount: Int { get set }

  /// The dictionary identity the context must still map to this exact node.
  var nodeIdentity: CogNodeIdentity { get }

  /// Invalidates stale grace completions when observation changes.
  var lifetimeReleaseGeneration: UInt64 { get set }

  /// Severs this node's forward and reverse dependency edges before removal.
  func releaseDependenciesForLifetime()
}

extension CogLifetimeLeaseNode {
  /// Adds one external owner without silently wrapping the count.
  func incrementExternalLeaseCount() {
    guard externalLeaseCount < Int.max else {
      fatalError("A Cog node's external lifetime lease count overflowed.")
    }
    externalLeaseCount += 1
  }

  /// Removes one external owner without hiding an ownership imbalance.
  func decrementExternalLeaseCount() {
    guard externalLeaseCount > 0 else {
      fatalError("A Cog node's external lifetime lease count underflowed.")
    }
    externalLeaseCount -= 1
  }

  /// Advances the generation without permitting wraparound to revive a stale task.
  @discardableResult
  func advanceLifetimeReleaseGeneration() -> UInt64 {
    guard lifetimeReleaseGeneration < UInt64.max else {
      fatalError("A Cog node's lifetime release generation overflowed.")
    }
    lifetimeReleaseGeneration += 1
    return lifetimeReleaseGeneration
  }
}
