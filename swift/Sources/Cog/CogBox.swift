/// A derived value computed separately for every key.
///
/// A box has one selector and one state per key used in a context. Subscript it
/// to get a ``Cog`` for that key:
///
/// ```swift
/// let isSunny = CogBox<Bool, ZipCode> { c, zip in
///   c[weatherReport[zip]]?.kind == .clear
/// }
/// ```
@MainActor
public struct CogBox<Value, Key: Hashable> {
  /// The one declaration behind every key of this box.
  internal let descriptor: DerivedCogDescriptor<Value>

  /// Declares a keyed derived value.
  ///
  /// - Parameters:
  ///   - keepAlive: Whether every key of this declaration has app lifetime
  ///     instead of the synchronous-derived `whileObserved` default.
  ///   - selector: How to compute one key's value. The key is an ordinary
  ///     lexical value; pass it to inner keyed reads explicitly.
  ///   - name: What Cog should call this declaration in diagnostics and debug
  ///     history. Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    keepAlive: Bool = false,
    _ selector: @escaping @MainActor (Reader<Value>, Key) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      selector: selector,
      equals: nil,
      lifetime: CogStateLifetime(keepAlive: keepAlive),
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// Declares a keyed derived value with an explicit equality rule.
  ///
  /// - Parameters:
  ///   - keepAlive: Whether every key of this declaration has app lifetime
  ///     instead of the synchronous-derived `whileObserved` default.
  ///   - selector: How to compute one key's value.
  ///   - equals: Whether the cached and newly computed values count as equal.
  ///   - name: What Cog should call this declaration in diagnostics and debug
  ///     history. Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    keepAlive: Bool = false,
    _ selector: @escaping @MainActor (Reader<Value>, Key) -> Value,
    equals: @escaping @MainActor (Value, Value) -> Bool,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      selector: selector,
      equals: equals,
      lifetime: CogStateLifetime(keepAlive: keepAlive),
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// The value reference naming this box's derived value for one key.
  public subscript(key: Key) -> Cog<Value> {
    Cog(descriptor: descriptor, key: key)
  }

  private static func makeDescriptor(
    selector: @escaping @MainActor (Reader<Value>, Key) -> Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    lifetime: CogStateLifetime,
    label: CogLabel
  ) -> DerivedCogDescriptor<Value> {
    DerivedCogDescriptor(
      selector: { c, erasedKey in
        guard let key = erasedKey as? Key else {
          fatalError(
            """
            A state of \(label) was asked to compute for \
            \(String(describing: erasedKey)), which is not a \(Key.self). \
            Only this box builds value references for its own declaration, so this \
            context's state storage is corrupt.
            """
          )
        }
        return selector(c, key)
      },
      equals: equals,
      lifetime: lifetime,
      label: label
    )
  }
}

extension CogBox where Value: Equatable {
  /// Declares an `Equatable` keyed derived value whose equal reruns stop the
  /// downstream wave independently for each key.
  ///
  /// Set `keepAlive` when every key should remain for the context's lifetime
  /// instead of following the synchronous-derived `whileObserved` default.
  public init(
    keepAlive: Bool = false,
    _ selector: @escaping @MainActor (Reader<Value>, Key) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      selector: selector,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: CogStateLifetime(keepAlive: keepAlive),
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }
}
