/// A read-only facade for a ``ManualCogBox``.
///
/// Keep a source box `fileprivate`, then publish its `.readOnly` projection:
///
/// ```swift
/// // WeatherState.swift
/// fileprivate let weatherReportSource = ManualCogBox<Weather?, ZipCode>(nil)
/// let weatherReport = weatherReportSource.readOnly
/// ```
///
/// Callers can then read `weatherReport[zip]`. The projection holds no state,
/// keys, or values.
@MainActor
public struct CogBoxProjection<Value, Key: Hashable> {
  /// The source box this projection reads.
  ///
  /// Internal so callers cannot recover or construct a writable source box.
  internal let source: ManualCogBox<Value, Key>

  /// The read-only value reference naming this box's state for one key.
  ///
  /// `readOnlyBox[5]` and `sourceBox[5]` name the same state.
  ///
  /// - Parameter key: Which of this declaration's values to name.
  /// - Returns: A read-only value reference for that key.
  public subscript(key: Key) -> CogProjection<Value> {
    CogProjection(source: source[key])
  }
}

// MARK: - Projecting a source box

extension ManualCogBox {
  /// A keyed declaration naming this box's state whose value references cannot be written.
  ///
  /// Publish this beside a `fileprivate` source box. Each projected key names
  /// the source box's state for that key.
  public var readOnly: CogBoxProjection<Value, Key> {
    CogBoxProjection(source: self)
  }
}
