/// A read-only facade for a ``ManualCog``.
///
/// `.readOnly` is the second half of the write-ownership rule. A source is
/// declared `fileprivate` so that only its own file can name it, and that file
/// then publishes this projection so the rest of the app can read the state
/// without being able to change it:
///
/// ```swift
/// // WeatherState.swift
/// fileprivate let currentZipSource = ManualCog<ZipCode?>(nil)
/// let currentZipCode = currentZipSource.readOnly
/// ```
///
/// The projection creates no state and stores no copy of the value. Reading it
/// is the same as reading its source.
///
/// The source stays hidden inside Cog, and ``Writer`` only accepts a
/// ``ManualCog``. Passing a `CogProjection` to a writer is a compile-time error.
@MainActor
public struct CogProjection<Value> {
  /// The source this value reference reads.
  ///
  /// Deliberately the only stored property, and deliberately internal. Storing
  /// the source rather than re-deriving a descriptor and key is what makes the
  /// projection free and keeps "same value reference, same state" true by construction;
  /// keeping it internal is what makes the projection one-way.
  ///
  /// Its memberwise initializer is internal for the same reason: the spelling
  /// users get is ``ManualCog/readOnly``, which reads as a property of the
  /// source rather than as a wrapper someone could also build around a source
  /// they were handed.
  internal let source: ManualCog<Value>
}

// MARK: - Projecting a source

extension ManualCog {
  /// A value reference naming this source's state that cannot be used to write it.
  ///
  /// Publish this next to the source, in the file that owns it, and keep the
  /// source itself `fileprivate`:
  ///
  /// ```swift
  /// fileprivate let weatherServiceSource = ManualCog<WeatherService>(.live)
  /// let weatherService = weatherServiceSource.readOnly
  /// ```
  ///
  /// Both value references name one state, so a write made through the source in that file
  /// is immediately what every reader of the projection sees.
  public var readOnly: CogProjection<Value> {
    CogProjection(source: self)
  }
}

// MARK: - Reading

extension Cogtext {
  /// Reads a read-only value reference's current value without creating a dependency edge.
  ///
  /// The same one-shot untracked read as the one for a source, on the
  /// same state — projecting a source changes who may write it, never how it is
  /// read or what a read means.
  ///
  /// - Parameter valueReference: The read-only value reference to read.
  /// - Returns: The value the source it names holds in this context.
  public func read<Value>(_ valueReference: CogProjection<Value>) -> Value {
    read(valueReference.source)
  }
}
