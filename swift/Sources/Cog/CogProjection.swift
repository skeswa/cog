/// A read-only facade for a ``ManualCog``.
///
/// Keep a source `fileprivate`, then publish its `.readOnly` projection:
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
  /// Internal so callers cannot recover or construct a writable source.
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
  /// The source and projection name the same state.
  public var readOnly: CogProjection<Value> {
    CogProjection(source: self)
  }
}

// MARK: - Reading

extension Cogtext {
  /// Reads a read-only value reference's current value without creating a dependency edge.
  ///
  /// - Parameter valueReference: The read-only value reference to read.
  /// - Returns: The value the source it names holds in this context.
  public func peek<Value>(_ valueReference: CogProjection<Value>) -> Value {
    peek(valueReference.source)
  }
}
