extension CogBox {
  /// A read-only keyed facade over one ``CogBox/Manual`` declaration.
  ///
  /// Keep a source box `private`, then publish its `.readOnly` projection under
  /// the source's name without the leading underscore:
  ///
  /// ```swift
  /// // WeatherState+Cogs.swift
  /// private let _weatherReportCogs = CogBox<Weather?, ZipCode>.Manual { nil }
  /// let weatherReportCogs = _weatherReportCogs.readOnly
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
  public struct Projection {
    /// The source box this projection reads.
    ///
    /// Internal so callers cannot recover or construct a writable source box.
    internal let sourceCogs: CogBox<Value, Key>.Manual

    /// The read-only value reference naming this box's state for one key.
    ///
    /// `readOnlyCogs[5]` and `sourceCogs[5]` name the same state.
    /// Building the projected reference allocates no descriptor or graph state.
    ///
    /// - Parameter key: Which of this declaration's values to name.
    /// - Returns: A read-only value reference for that key.
    public subscript(key: Key) -> Cog<Value>.Projection {
      Cog.Projection(sourceCog: sourceCogs[key])
    }
  }
}

// MARK: - Projecting a source box

extension CogBox.Manual {
  /// A keyed declaration naming this box's state whose value references cannot be written.
  ///
  /// Publish this beside a `private` source box. Each projected key keeps
  /// the source descriptor-and-key identity, equality behavior, starting value,
  /// and context-local state; only write capability is removed.
  public var readOnly: CogBox<Value, Key>.Projection {
    CogBox.Projection(sourceCogs: self)
  }
}
