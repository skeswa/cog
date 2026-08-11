/// A writable source of state.
///
/// Declare one at the top of the file that owns the state, and keep the
/// declaration `fileprivate` (or `private` inside a type) so only that file can
/// write it. Expose reads to everyone else, and put the ops that write it in
/// the same file (§4):
///
/// ```swift
/// fileprivate let currentZipSource = ManualCog<ZipCode?>(nil)
/// ```
///
/// A `ManualCog` is a *ref*: a small value naming one piece of state, not the
/// state itself. The state lives in the app's one context, which creates a node
/// for this ref the first time something needs it (§2.3). Copying a ref, or
/// building the same ref twice, still names the same state — so the ref is safe
/// to pass around, and holding one is not holding a value.
///
/// Give the declaration a `name:` when the default label — the file and line it
/// was declared on — would not read well in a cycle diagnostic or in debug
/// history. The name is a label only: two cogs declared with the same name are
/// still two different cogs.
@MainActor
public struct ManualCog<Value> {
  /// The declaration this ref names.
  internal let descriptor: ManualCogDescriptor<Value>

  /// Which node of `descriptor` this ref names, or `nil` for a keyless
  /// declaration.
  ///
  /// Inline `AnyHashable?` is the correctness build's key representation and
  /// stays an implementation detail: the ref is deliberately not `@frozen`, so
  /// benchmarks can still choose a different layout (perf §4, §9).
  internal let key: AnyHashable?

  /// Declares a source of state that starts at `startingValue`.
  ///
  /// Declaring allocates one descriptor and returns a ref already bound to it.
  /// It creates no node and touches no context; the starting value is only what
  /// a node begins at, whenever one is first needed.
  ///
  /// - Parameters:
  ///   - startingValue: The value reads see until something writes.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: ManualCogDescriptor(
        startingValue: startingValue,
        equals: nil,
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Declares a source with an explicit rule for deciding whether a write
  /// changes its value.
  ///
  /// Cog calls `equals` once at flush with the latest completed value and the
  /// final value staged by the turn. Returning `true` suppresses downstream
  /// work; returning `false` commits and propagates the new value. This also
  /// makes a change followed by a reversion in one turn count as no change.
  ///
  /// - Parameters:
  ///   - startingValue: The value reads see until something writes.
  ///   - equals: Whether the old and newly staged values count as equal.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: Value,
    equals: @escaping @MainActor (Value, Value) -> Bool,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: ManualCogDescriptor(
        startingValue: startingValue,
        equals: equals,
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Builds a ref for an existing declaration, which is how a box makes a ref
  /// for one of its keys without allocating a second descriptor.
  internal init(descriptor: ManualCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
  }
}

extension ManualCog where Value: Equatable {
  /// Declares an `Equatable` source whose equal writes are not changes.
  ///
  /// This overload is selected automatically when `Value` conforms to
  /// `Equatable`. Use ``init(_:equals:name:fileID:line:)`` to substitute a
  /// domain-specific equality rule.
  public init(
    _ startingValue: Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: ManualCogDescriptor(
        startingValue: startingValue,
        equals: { oldValue, newValue in oldValue == newValue },
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }
}
