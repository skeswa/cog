public import Cog

/// A derived dependency cycle observed without terminating the test process.
///
/// This is a narrow behavior contract for scenario tests. It contains only the
/// rendered path and failure message, never graph nodes, edges, stack frames,
/// descriptor identities, or another core-specific representation.
public nonisolated struct CogCycleDiagnostic: Sendable, Equatable {
  /// The exact closed path, including the repeated final cog.
  public let path: [String]

  /// The message Cog would use when the corresponding read fails.
  public let message: String

  fileprivate init(_ snapshot: CogCycleDiagnosticSnapshot) {
    path = snapshot.path
    message = snapshot.message
  }
}

extension Reader {
  /// Returns the cycle that reading `ref` now would close, if there is one.
  ///
  /// Call this only as a test diagnostic from the active selector. It records
  /// no dependency and creates no node. A `nil` result means the read would not
  /// close the current derived-computation path.
  public func cycleDiagnostic<Read>(
    ifReading ref: Cog<Read>
  ) -> CogCycleDiagnostic? {
    cycleDiagnosticSnapshot(ifReading: ref).map(CogCycleDiagnostic.init)
  }
}
