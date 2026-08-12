public import Cog

/// A derived dependency cycle observed without terminating the test process.
///
/// Scenario tests receive the rendered path and failure message without access
/// to graph storage.
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
  /// Returns the cycle that reading `valueReference` now would close, if there is one.
  ///
  /// Call this only as a test diagnostic from the active selector. It records
  /// no dependency and creates no state. A `nil` result means the read would not
  /// close the current derived-computation path.
  public func cycleDiagnostic<Read>(
    ifReading valueReference: Cog<Read>
  ) -> CogCycleDiagnostic? {
    cycleDiagnosticSnapshot(ifReading: valueReference).map(CogCycleDiagnostic.init)
  }
}
