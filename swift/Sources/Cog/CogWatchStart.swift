/// Whether installing a watch calls its body once before anything changes.
///
/// Installation always reads the watched cog to subscribe and capture a
/// baseline. This option controls only the initial body call.
public nonisolated enum CogWatchStart: Sendable, Equatable {
  /// Install quietly.
  ///
  /// The body first runs after a change. It receives the install-time value as
  /// `oldValue`. For example, installing a weather alert does not report
  /// weather that already exists.
  case skip

  /// Call the body once at install time.
  ///
  /// The first call receives the current value as both `oldValue` and
  /// `newValue`. Later calls report changes.
  case run
}
