/// A value computed from other cogs.
///
/// Declare one next to the state it summarizes, and write it as a plain
/// function of the cogs it reads (§3.1):
///
/// ```swift
/// let isNiceOutsideHere = Cog<Bool> { c in
///   guard let zip = c.get(currentZipCode) else { return false }
///   return c.get(isNiceOutside[zip])
/// }
/// ```
///
/// The `c` handed to the selector is a ``Reader``, and `c.get` is how the
/// selector reads. Reading through it is what makes the read a *dependency*:
/// Cog notes which cogs this run actually read, so it knows what this value is
/// made of (§2.4). Read with `c.get` and the value stays right on its own; read
/// around it — a captured `let`, a global, a stored property — and it will not.
///
/// A `Cog` is a *value reference*, exactly like a ``ManualCog``: a small value naming one
/// derived value, not the value itself. Declaring runs nothing. The selector
/// runs for the first time when something first reads the value reference in a context, and
/// the value it produced is kept, so reading twice does not compute twice.
/// Neither the declaration nor the value reference is where the value lives — it lives in
/// the app's one context (§2.3), so the same declaration is computed
/// separately, and cached separately, in a test or preview runtime.
///
/// Selectors are ordinary synchronous functions of their inputs. Keep them
/// cheap, keep them pure, and let them return early or branch however the logic
/// reads best — the dependencies are whatever the run read this time. A
/// synchronous selector cannot `throw` in v1: return a `Result` for fallible
/// domain work, and reach for an `AsyncCog` when the work has to await (§2.4).
///
/// Give the declaration a `name:` when the default label — the file and line it
/// was declared on — would not read well in a cycle diagnostic or in debug
/// history. The name is a label only: two cogs declared with the same name are
/// still two different cogs.
@MainActor
public struct Cog<Value> {
  /// The declaration this value reference names.
  internal let descriptor: DerivedCogDescriptor<Value>

  /// Which state of `descriptor` this value reference names, or `nil` for a keyless
  /// declaration.
  ///
  /// A keyless cog is the single-state case of the same descriptor-and-key
  /// storage rule rather than a second mechanism (§2.3). Inline `AnyHashable?`
  /// is the correctness build's key representation and stays an implementation
  /// detail: the value reference is deliberately not `@frozen`, so benchmarks can still
  /// choose a different layout (perf §4, §9).
  internal let key: AnyHashable?

  /// Declares a value computed by `selector`.
  ///
  /// Declaring allocates one descriptor and returns a value reference already bound to it.
  /// It creates no state, touches no context, and — the part worth saying out
  /// loud — does not run `selector`. Nothing about a declaration is work
  /// (§2.3).
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
        selector: { reader, _ in selector(reader) },
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
        selector: { reader, _ in selector(reader) },
        equals: equals,
        lifetime: CogStateLifetime(keepAlive: keepAlive),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Builds a value reference for an existing declaration, which is how a derived box
  /// makes a value reference for one of its keys without allocating a second descriptor.
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
        selector: { reader, _ in selector(reader) },
        equals: { oldValue, newValue in oldValue == newValue },
        lifetime: CogStateLifetime(keepAlive: keepAlive),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }
}
