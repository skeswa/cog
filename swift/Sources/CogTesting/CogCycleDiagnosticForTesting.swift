public import Cog

/// An automatic dependency cycle observed without terminating the test process.
///
/// Scenario tests receive the rendered path and failure message without access
/// to graph storage.
public nonisolated struct CogCycleDiagnostic: Sendable, Equatable {
  /// The exact closed path, including the repeated final cog.
  public let path: [String]

  /// The message Cog would use when the corresponding read fails.
  public let message: String

  /// Copies the internal snapshot into representation-independent test data.
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
  /// close the current automatic-computation path.
  ///
  /// - Parameter valueReference: The automatic value whose hypothetical read is
  ///   checked against the active computation path.
  /// - Returns: The closed path and fatal-error text that a real cyclic read
  ///   would produce, or `nil` when the read is acyclic.
  public func cycleDiagnostic<Read>(
    ifReading valueReference: Cog<Read>
  ) -> CogCycleDiagnostic? {
    cycleDiagnosticSnapshot(ifReading: valueReference).map(CogCycleDiagnostic.init)
  }
}
