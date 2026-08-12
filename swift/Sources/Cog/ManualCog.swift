/// A writable source of state.
///
/// Declare one at the top of the file that owns the state, and keep the
/// declaration `fileprivate` (or `private` inside a type) so only that file can
/// write it. Expose reads to everyone else, and put the ops that write it in
/// the same file:
///
/// ```swift
/// fileprivate let currentZipSource = ManualCog<ZipCode?>(nil)
/// ```
///
/// A `ManualCog` names state stored in a ``Cogtext``. Copying the reference
/// still names the same state. A test or preview uses separate state in its own
/// context.
///
/// Pass `name:` when `fileID:line` would be unclear in diagnostics or history.
/// Names do not define identity.
@MainActor
public struct ManualCog<Value> {
  /// The declaration this value reference names.
  internal let descriptor: ManualCogDescriptor<Value>

  /// The keyed state this reference names, or `nil` for a keyless declaration.
  ///
  /// The correctness core stores an inline `AnyHashable?`. The type is not
  /// `@frozen`, so benchmarks may select another layout (perf §4, §9).
  internal let key: AnyHashable?

  /// Declares a source of state that starts at `startingValue`.
  ///
  /// This allocates one descriptor. A context creates the state on first use.
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

  /// Builds a keyed reference without allocating another descriptor.
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
