/// A family of synchronously derived values sharing one declaration.
///
/// A box owns one descriptor and selector. Each descriptor-and-key pair names
/// independent cached state and dependencies in a context. Equal keys resolve
/// to the same state; unequal keys do not affect one another unless their
/// selectors read shared producers. Subscript the box to get a ``Cog`` for one
/// key:
///
/// ```swift
/// let isSunnyCogs = CogBox<Bool, ZipCode> { c, zip in
///   let weatherReport = c[weatherReportCogs[zip]]
///   return weatherReport?.kind == .clear
/// }
/// ```
///
/// The plural final `Cogs` suffix distinguishes the box from any one keyed
/// ``Cog`` it produces.
///
/// Constructing or subscripting a box is inert. A context creates and computes
/// a key's state on its first tracked, UI, or one-shot read. Copies retain
/// descriptor identity, while a different box declaration remains distinct
/// even when it uses the same key and selector. Every selector and equality
/// comparison runs synchronously on the MainActor. A tracked read records the
/// exact keyed state as a dependency; a one-shot peek settles it without adding
/// an edge.
@MainActor
public struct CogBox<Value, Key: Hashable> {
  /// Stable declaration identity and behavior shared by every key and box copy.
  internal let descriptor: DerivedCogDescriptor<Value>

  /// Builds a keyed facade over an existing derived declaration.
  ///
  /// Async value projections use this path to expose their shared projection
  /// descriptor with normal keyed-`Cog` spelling. It allocates neither a new
  /// descriptor nor context state.
  internal init(descriptor: DerivedCogDescriptor<Value>) {
    self.descriptor = descriptor
  }

  /// Declares a keyed derived value.
  ///
  /// Each key records only the producers read during that key's most recent
  /// selector run. Without an equality rule, every rerun counts as a changed
  /// value and continues the downstream invalidation wave. Use the explicit
  /// `equals` initializer or the `Equatable` overload when equal reruns should
  /// stop that wave.
  ///
  /// - Parameters:
  ///   - selector: MainActor computation for one key. The key is an ordinary
  ///     lexical value; pass it to inner keyed reads explicitly. Reads through
  ///     `c[...]` replace this key's dependency set on every run.
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
      lifetime: .whileObserved(grace: nil),
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// Declares a keyed derived value with an explicit equality rule.
  ///
  /// Equality is evaluated after a rerun. Returning `true` preserves the cached
  /// value and stops downstream work for that key, but it does not prevent the
  /// selector itself from running when a dependency may have changed. Each key
  /// maintains its own cache and applies the rule independently.
  ///
  /// - Parameters:
  ///   - selector: MainActor computation for one key and its current tracked
  ///     dependencies.
  ///   - equals: MainActor comparison of the cached value and fresh result.
  ///     Return `true` to retain the cache and stop the downstream wave.
  ///   - name: What Cog should call this declaration in diagnostics and debug
  ///     history. Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
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
      lifetime: .whileObserved(grace: nil),
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// The value reference naming this box's derived value for one key.
  ///
  /// This operation only packages the box's descriptor with `key`. Equal keys
  /// therefore name the same state in a context, and repeated subscripting
  /// does not allocate descriptors or compute the selector.
  ///
  /// - Parameter key: The hashable value completing this state's identity.
  /// - Returns: A lightweight derived value reference for that key.
  public subscript(key: Key) -> Cog<Value> {
    Cog(descriptor: descriptor, key: key)
  }

  /// Builds the single type-erased descriptor shared by all keys.
  ///
  /// Keeping erasure at the descriptor boundary lets public value references
  /// stay small while still failing clearly if internal storage ever pairs the
  /// declaration with a key of the wrong type.
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
  /// The synthesized equality rule affects only propagation after the selector
  /// reruns; dependencies still settle and the selector still recomputes when
  /// required.
  ///
  /// - Parameters:
  ///   - selector: MainActor computation and dependency selection for one key.
  ///   - name: The declaration label used in diagnostics and debug history.
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
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: .whileObserved(grace: nil),
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }
}
