/// A derived state whose context may release it when no durable consumer holds it.
///
/// Reactions lease the derived roots they read, and a UI boundary pins its exact
/// state separately. Internal dependency edges block removal while their
/// consumer remains stored, but do not renew observation or earn another grace
/// window. This separation lets an expired unobserved dependency leave with the
/// consumer whose removal disconnects it. The context is the sole release
/// coordinator; every field and transition below is MainActor-confined.
@MainActor
internal protocol CogLifetimeLeaseState: CogState {
  /// The declaration policy that decides whether release eligibility applies.
  var lifetime: CogStateLifetime { get }

  /// How many exact reaction-owned consumers currently keep this state observed.
  ///
  /// UI pinning is represented by the observation boundary instead of this
  /// count; internal graph subscribers are intentionally excluded from both.
  var externalLeaseCount: Int { get set }

  /// The dictionary identity the context must still map to this exact state.
  ///
  /// Release checks pair this value with object identity so a stale grace task
  /// cannot remove a newly created state that reused the same declaration/key.
  var stateIdentity: CogStateIdentity { get }

  /// Invalidates stale grace completions when observation changes.
  ///
  /// Every lease acquisition or renewed transient demand advances this value;
  /// an earlier sleeping task may wake, but it cannot release the state.
  var lifetimeReleaseGeneration: UInt64 { get set }

  /// The current generation whose grace deadline has not arrived yet.
  ///
  /// An unobserved dependency can join a consumer's release cascade only when
  /// it has no separately pending deadline. The deadline task clears this
  /// before checking subscribers, so an earlier elapsed grace does not add a
  /// second window after its last internal consumer leaves.
  var pendingLifetimeReleaseGeneration: UInt64? { get set }

  /// The one currently sleeping expiry task for this state, if any.
  ///
  /// Renewing grace cancels and replaces this task instead of leaving an older
  /// sleeper alive until its obsolete deadline. Generation and identity checks
  /// remain necessary because cancellation and deadline resumption can race.
  /// The task holds context and state weakly, so an outstanding deadline cannot
  /// keep either owner alive through teardown.
  var lifetimeReleaseTask: Task<Void, Never>? { get set }

  /// Severs this state's forward and reverse dependency edges before removal.
  ///
  /// Surviving producers must no longer invalidate the removed consumer. Edge
  /// removal can also disconnect unobserved producers, which the context visits
  /// in the same deadline cascade when their own grace has already elapsed.
  func releaseDependenciesForLifetime()

  /// Cancels state-owned work and invalidates late completions before removal.
  ///
  /// The context invokes this before removing the storage slot or dependency
  /// edges. Async state therefore advances task generation while its identity is
  /// still intact; synchronous state has no additional preparation.
  func prepareForLifetimeRelease()
}

extension CogLifetimeLeaseState {
  /// Synchronous derived states own only their grace-expiry task.
  func prepareForLifetimeRelease() {
    cancelPendingLifetimeRelease()
  }

  /// Cancels the one outstanding grace task and invalidates its generation.
  ///
  /// Generation advances before cancellation and slot clearing. A sleeper that
  /// has already resumed therefore fails validation even if cooperative task or
  /// controlled-clock cancellation is delivered too late.
  func cancelPendingLifetimeRelease() {
    advanceLifetimeReleaseGeneration()
    pendingLifetimeReleaseGeneration = nil
    lifetimeReleaseTask?.cancel()
    lifetimeReleaseTask = nil
  }

  /// Adds one external owner without silently wrapping the exact lease count.
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

  /// Advances the generation without permitting wraparound to validate stale grace.
  @discardableResult
  func advanceLifetimeReleaseGeneration() -> UInt64 {
    guard lifetimeReleaseGeneration < UInt64.max else {
      fatalError("A Cog state's lifetime release generation overflowed.")
    }
    lifetimeReleaseGeneration += 1
    return lifetimeReleaseGeneration
  }
}
