/// A keyed declaration whose value references can be read and not written.
///
/// What ``ReadOnlyCog`` is to a ``ManualCog``, this is to a ``ManualCogBox``:
/// the projection a file publishes so that everyone can read per-key state
/// while only that file can name the source that writes it. The design's
/// weather example publishes exactly this —
///
/// ```swift
/// // WeatherState.swift
/// fileprivate let weatherReportSource = ManualCogBox<Weather?, ZipCode>(nil)
/// let weatherReport = weatherReportSource.readOnly
/// ```
///
/// — and callers then write `weatherReport[zip]` wherever they would have
/// written `weatherReportSource[zip]`, for a read.
///
/// Like the box it projects, this is a declaration and not a collection: it
/// holds no keys and no values, it never has to be told which keys exist, and
/// `box[key]` builds a value reference rather than looking anything up.
/// Projecting the box creates no graph state or second descriptor.
@MainActor
public struct ReadOnlyCogBox<Value, Key: Hashable> {
  /// The source box this projection reads.
  ///
  /// Internal, for the reason ``ReadOnlyCog/source`` is: the projection has to
  /// be one-way, or `fileprivate` on the source would buy nothing.
  ///
  /// Its memberwise initializer is internal for the same reason: the spelling
  /// users get is ``ManualCogBox/readOnly``.
  internal let source: ManualCogBox<Value, Key>

  /// The read-only value reference naming this box's state for one key.
  ///
  /// The same value reference the source box's subscript would build for that key, in the
  /// type that cannot be written: `readOnlyBox[5]` and `sourceBox[5]` name one
  /// state, so a write through the source shows up through the projection.
  ///
  /// - Parameter key: Which of this declaration's values to name.
  /// - Returns: A read-only value reference for that key.
  public subscript(key: Key) -> ReadOnlyCog<Value> {
    ReadOnlyCog(source: source[key])
  }
}

// MARK: - Projecting a source box

extension ManualCogBox {
  /// A keyed declaration naming this box's state whose value references cannot be written.
  ///
  /// Publish this next to the box, in the file that owns it, and keep the box
  /// itself `fileprivate`. Every key of the projection names the state that
  /// key names in the source, so nothing about which keys exist, or what they
  /// start at, changes.
  public var readOnly: ReadOnlyCogBox<Value, Key> {
    ReadOnlyCogBox(source: self)
  }
}
