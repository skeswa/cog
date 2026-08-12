/// Whether installing a watch calls its body once before anything changes.
///
/// This chooses only whether the *body* runs at install time. Either way the
/// installing run reads the watched cog, because that read is what subscribes
/// the watch and what captures the value the first change will hand back as
/// its old one. `.skip` buys a quieter install, never a missed wake-up.
public nonisolated enum CogWatchStart: Sendable, Equatable {
  /// Install quietly.
  ///
  /// The body first runs when the watched value really changes, and receives
  /// the value as of install time as its old value. This is what an effect
  /// that should fire on transitions wants: installing a weather alert should
  /// not alert about weather that was already there.
  case skip

  /// Call the body once at install time.
  ///
  /// An install has no transition to report, so the current value arrives as
  /// both the old and the new value. This is what an effect that reconciles
  /// the world to a value wants: it should do its work once for the value that
  /// is already there, and again whenever that value changes.
  case run
}
