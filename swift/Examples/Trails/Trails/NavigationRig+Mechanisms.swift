import Cog

/// Records every screen transition into the session journal.
///
/// This is the analytics pattern with the analytics service replaced by a
/// visible in-app log. One reaction on `currentScreenCog` observes navigation
/// from taps, gestures, deep links, and restoration without per-screen code.
/// Its write queues in a later turn after the navigation turn.
struct TrailJournalMechanism: Mechanism {
  /// Watches the derived screen and appends each settled transition.
  ///
  /// `initial: .run` records the restored screen as the session's first
  /// entry, because the persistence mechanism is listed first at assembly.
  ///
  /// - Parameter m: Assembly-only controller owned by the runtime scope.
  func operate(_ m: MechanismController) {
    m.watch(currentScreenCog, initial: .run, name: "journal") { [weak m] _, screen in
      m?.recordScreenVisit(screen)
    }
  }
}
