/// A derived value computed separately for every key.
///
/// A box is one declaration with one selector. Subscript it at the point of
/// use to make a ``Cog`` ref for a key; the context creates and caches one node
/// per descriptor-and-key pair. The selector receives that key as an ordinary
/// argument, so keyed dependencies flow through normal lexical capture:
///
/// ```swift
/// let isSunny = CogBox<Bool, ZipCode> { c, zip in
///   c.get(weatherReport[zip])?.kind == .clear
/// }
/// ```
@MainActor
public struct CogBox<Value, Key: Hashable> {
  /// The one declaration behind every key of this box.
  internal let descriptor: DerivedCogDescriptor<Value>

  /// Declares a keyed derived value.
  ///
  /// - Parameters:
  ///   - selector: How to compute one key's value. The key is an ordinary
  ///     lexical value; pass it to inner keyed reads explicitly.
  ///   - name: What Cog should call this declaration in diagnostics and debug
  ///     history. Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ selector: @escaping @MainActor (Reader<Value>, Key) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      selector: selector,
      equals: nil,
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// Declares a keyed derived value with an explicit equality rule.
  public init(
    _ selector: @escaping @MainActor (Reader<Value>, Key) -> Value,
    equals: @escaping @MainActor (Value, Value) -> Bool,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      selector: selector,
      equals: equals,
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// The ref naming this box's derived value for one key.
  public subscript(key: Key) -> Cog<Value> {
    Cog(descriptor: descriptor, key: key)
  }

  private static func makeDescriptor(
    selector: @escaping @MainActor (Reader<Value>, Key) -> Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    label: CogLabel
  ) -> DerivedCogDescriptor<Value> {
    DerivedCogDescriptor(
      selector: { reader, erasedKey in
        guard let key = erasedKey as? Key else {
          fatalError(
            """
            A node of \(label) was asked to compute for \
            \(String(describing: erasedKey)), which is not a \(Key.self). \
            Only this box builds refs for its own declaration, so this \
            context's node storage is corrupt.
            """
          )
        }
        return selector(reader, key)
      },
      equals: equals,
      label: label
    )
  }
}

extension CogBox where Value: Equatable {
  /// Declares an `Equatable` keyed derived value whose equal reruns stop the
  /// downstream wave independently for each key.
  public init(
    _ selector: @escaping @MainActor (Reader<Value>, Key) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      selector: selector,
      equals: { oldValue, newValue in oldValue == newValue },
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }
}
