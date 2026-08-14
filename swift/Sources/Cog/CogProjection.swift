/// A read-only value reference for one ``ManualCog`` declaration.
///
/// Keep a source `fileprivate`, then publish its `.readOnly` projection:
///
/// ```swift
/// // WeatherState.swift
/// fileprivate let currentZipSourceCog = ManualCog<ZipCode?>(nil)
/// let currentZipCog = currentZipSourceCog.readOnly
/// ```
///
/// The projection creates no descriptor or state and stores no copy of the
/// value. It preserves the source's descriptor-and-key identity, app lifetime,
/// starting value, and equality behavior, so reading it is exactly the same
/// graph read as reading its source.
///
/// The source stays hidden inside Cog, and ``Writer`` only accepts a
/// ``ManualCog``. Passing a `CogProjection` to a writer is a compile-time error.
/// The facade is MainActor-isolated with the graph; keep the source private in
/// the owning state file because projection itself is an API boundary, not a
/// replacement for Swift access control.
@MainActor
public struct CogProjection<Value> {
  /// The source this value reference reads.
  ///
  /// Internal so callers cannot recover or construct a writable source.
  internal let sourceCog: ManualCog<Value>
}

// MARK: - Projecting a source

extension ManualCog {
  /// A value reference naming this source's state that cannot be used to write it.
  ///
  /// Publish this next to the source, in the file that owns it, and keep the
  /// source itself `fileprivate`:
  ///
  /// ```swift
  /// fileprivate let weatherServiceSourceCog = ManualCog<WeatherService>(.live)
  /// let weatherServiceCog = weatherServiceSourceCog.readOnly
  /// ```
  ///
  /// The source and projection name the same state in every context. Accessing
  /// this property allocates no new descriptor and does not create state.
  public var readOnly: CogProjection<Value> {
    CogProjection(sourceCog: self)
  }
}

// MARK: - Reading

extension Cogs {
  /// Reads a read-only value reference's current value without creating a dependency edge.
  ///
  /// This one-shot read observes the latest completed turn and never sees a
  /// value staged by an in-progress commit. Use a ``Reader`` or
  /// ``ReactionReader`` subscript when later writes should retrigger work.
  ///
  /// - Parameter valueReference: The read-only value reference to read.
  /// - Returns: The value the source it names holds in this context.
  public func peek<Value>(_ valueReference: CogProjection<Value>) -> Value {
    peek(valueReference.sourceCog)
  }
}
