/// Whether a newly installed watch reports its initial baseline.
///
/// Installation always reads the watched cog to subscribe and capture a
/// baseline, acquires the same lifetime lease either way, and runs on the
/// MainActor before registration returns when installation occurs outside a
/// flush. This option controls only whether that initial tracking run invokes
/// the user's watch body; it does not change later equality filtering.
///
/// The value is `nonisolated`, `Sendable`, and contains no graph identity or
/// mutable state.
public nonisolated enum CogWatchStart: Sendable, Equatable {
  /// Install quietly.
  ///
  /// The body first runs after a change. It receives the install-time value as
  /// `oldValue` and the first changed value as `newValue`. For example,
  /// installing a weather alert does not report weather that already exists.
  case skip

  /// Call the body once at install time.
  ///
  /// The first call receives the current value as both `oldValue` and
  /// `newValue`; it establishes no artificial change. Later calls report
  /// equality-gated transitions from the previous delivered baseline.
  case run
}
