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
  /// close the current derived-computation path.
  ///
  /// - Parameter valueReference: The derived value whose hypothetical read is
  ///   checked against the active computation path.
  /// - Returns: The closed path and fatal-error text that a real cyclic read
  ///   would produce, or `nil` when the read is acyclic.
  public func cycleDiagnostic<Read>(
    ifReading valueReference: Cog<Read>
  ) -> CogCycleDiagnostic? {
    cycleDiagnosticSnapshot(ifReading: valueReference).map(CogCycleDiagnostic.init)
  }

  #if COG_VALUE_REFERENCE_LAYOUT_GENERIC
  /// Returns the cycle that reading one generic candidate keyed value would close.
  ///
  /// The key remains concrete at this public testing boundary; Cog erases it
  /// only after the read enters the current simple correctness core.
  ///
  /// - Parameter valueReference: The keyed derived value whose hypothetical
  ///   read is checked against the active computation path.
  /// - Returns: The closed path and fatal-error text that a real cyclic read
  ///   would produce, or `nil` when the read is acyclic.
  public func cycleDiagnostic<Read, Key: Hashable>(
    ifReading valueReference: CogBox<Read, Key>.ValueReference
  ) -> CogCycleDiagnostic? {
    cycleDiagnosticSnapshot(ifReading: valueReference).map(CogCycleDiagnostic.init)
  }
  #endif
}
