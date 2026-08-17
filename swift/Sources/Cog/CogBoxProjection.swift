/// A read-only keyed facade over one ``ManualCogBox`` declaration.
///
/// Keep a source box `fileprivate`, then publish its `.readOnly` projection:
///
/// ```swift
/// // WeatherState.swift
/// fileprivate let weatherReportSourceCogs = ManualCogBox<Weather?, ZipCode>(nil)
/// let weatherReportCogs = weatherReportSourceCogs.readOnly
/// ```
///
/// The projection holds the source box's descriptor identity but no keys,
/// states, or copied values. Equal keys name the same app-lifetime manual state
/// through either facade, so reads remain singular while ``Writer`` accepts
/// only the hidden writable references. Creating or subscripting the projection
/// is inert; a context creates a key's state on first use.
///
/// The facade is MainActor-isolated with the source it names. It is an access
/// boundary, not a security boundary: keep the source declaration private in
/// the file that owns its write operations.
@MainActor
public struct CogBoxProjection<Value, Key: Hashable> {
  /// The source box this projection reads.
  ///
  /// Internal so callers cannot recover or construct a writable source box.
  internal let sourceCogs: ManualCogBox<Value, Key>

  #if COG_VALUE_REFERENCE_LAYOUT_GENERIC
  /// A read-only keyed reference that retains the source box's concrete key.
  ///
  /// It wraps the generic candidate's writable reference without exposing that
  /// reference to callers, preserving the same compile-time write boundary as
  /// ``CogProjection``.
  public struct ValueReference {
    /// The hidden writable reference whose state this projection reads.
    internal let sourceReference: ManualCogBox<Value, Key>.ValueReference

    /// Adapts the candidate after it enters the class-state runtime shell.
    internal var simpleCoreReference: CogProjection<Value> {
      CogProjection(sourceCog: sourceReference.simpleCoreReference)
    }
  }
  #endif

  /// The read-only value reference naming this box's state for one key.
  ///
  /// `readOnlyCogs[5]` and `sourceCogs[5]` name the same state.
  /// Building the projected reference allocates no descriptor or graph state.
  ///
  /// - Parameter key: Which of this declaration's values to name.
  /// - Returns: A read-only value reference for that key.
  #if COG_VALUE_REFERENCE_LAYOUT_GENERIC
  public subscript(key: Key) -> ValueReference {
    ValueReference(sourceReference: sourceCogs[key])
  }
  #else
  public subscript(key: Key) -> CogProjection<Value> {
    CogProjection(sourceCog: sourceCogs[key])
  }
  #endif
}

// MARK: - Projecting a source box

extension ManualCogBox {
  /// A keyed declaration naming this box's state whose value references cannot be written.
  ///
  /// Publish this beside a `fileprivate` source box. Each projected key keeps
  /// the source descriptor-and-key identity, equality behavior, starting value,
  /// and context-local state; only write capability is removed.
  public var readOnly: CogBoxProjection<Value, Key> {
    CogBoxProjection(sourceCogs: self)
  }
}
