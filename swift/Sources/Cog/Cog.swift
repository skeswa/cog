/// A value derived from other cogs.
///
/// Declare one next to the state it summarizes, and write it as a plain
/// function of the cogs it reads:
///
/// ```swift
/// let isNiceOutsideHere = Cog<Bool> { c in
///   guard let zip = c[currentZipCode] else { return false }
///   return c[isNiceOutside[zip]]
/// }
/// ```
///
/// The selector reads through its ``Reader``. Each `c[valueReference]` records a
/// dependency, so changes can update this value. Reads from captured values,
/// globals, or stored properties are invisible to Cog.
///
/// A `Cog` names a derived value. The value lives in a ``Cogtext``. Its first
/// read in a context runs the selector, and later reads use the cached result
/// until a dependency changes. Tests and previews compute their own values in
/// their own contexts.
///
/// Keep selectors synchronous, cheap, and free of side effects. They may
/// branch or return early; each run replaces the dependency set. A selector
/// cannot `throw` in v1. Return `Result` for fallible domain work, or use an
/// `AsyncCog` when the work must await.
///
/// Pass `name:` when `fileID:line` would be unclear in diagnostics or history.
/// Names do not define identity.
@MainActor
public struct Cog<Value> {
  /// The declaration this value reference names.
  internal let descriptor: DerivedCogDescriptor<Value>

  /// The keyed state this reference names, or `nil` for a keyless declaration.
  ///
  /// The correctness core stores an inline `AnyHashable?`. The type is not
  /// `@frozen`, so benchmarks may select another layout (perf §4, §9).
  internal let key: AnyHashable?

  /// Declares a value computed by `selector`.
  ///
  /// This allocates one descriptor. It creates no state and does not run
  /// `selector` (§2.3).
  ///
  /// - Parameters:
  ///   - keepAlive: Whether this declaration has app lifetime instead of the
  ///     synchronous-derived `whileObserved` default.
  ///   - selector: How to compute the value. Read other cogs through the
  ///     ``Reader`` it is given, and read nothing any other way.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    keepAlive: Bool = false,
    _ selector: @escaping @MainActor (Reader<Value>) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: DerivedCogDescriptor(
        selector: { c, _ in selector(c) },
        equals: nil,
        lifetime: CogStateLifetime(keepAlive: keepAlive),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Declares a derived value with an explicit equality rule.
  ///
  /// Cog calls `equals` after a rerun with the cached value and the newly
  /// computed value. Returning `true` keeps the cached value and stops the
  /// downstream wave; returning `false` commits the new value and lets
  /// downstream cogs follow it.
  ///
  /// - Parameters:
  ///   - keepAlive: Whether this declaration has app lifetime instead of the
  ///     synchronous-derived `whileObserved` default.
  ///   - selector: How to compute the value. Read other cogs through the
  ///     ``Reader`` it is given, and read nothing any other way.
  ///   - equals: Whether the cached and newly computed values count as equal.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    keepAlive: Bool = false,
    _ selector: @escaping @MainActor (Reader<Value>) -> Value,
    equals: @escaping @MainActor (Value, Value) -> Bool,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: DerivedCogDescriptor(
        selector: { c, _ in selector(c) },
        equals: equals,
        lifetime: CogStateLifetime(keepAlive: keepAlive),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Builds a keyed reference without allocating another descriptor.
  internal init(descriptor: DerivedCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
  }
}

extension Cog where Value: Equatable {
  /// Declares an `Equatable` derived value whose equal reruns stop the wave.
  ///
  /// This overload is selected automatically when `Value` conforms to
  /// `Equatable`. Use ``init(keepAlive:_:equals:name:fileID:line:)`` to
  /// substitute a domain-specific equality rule.
  public init(
    keepAlive: Bool = false,
    _ selector: @escaping @MainActor (Reader<Value>) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: DerivedCogDescriptor(
        selector: { c, _ in selector(c) },
        equals: { oldValue, newValue in oldValue == newValue },
        lifetime: CogStateLifetime(keepAlive: keepAlive),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }
}
