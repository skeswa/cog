/// A declaration and value reference for one writable source of truth.
///
/// Declare one at the top of the file that owns the state, and keep the
/// declaration `fileprivate` (or `private` inside a type) so only that file can
/// write it. Expose reads to everyone else, and put the ops that write it in
/// the same file:
///
/// ```swift
/// fileprivate let currentZipSourceCog = ManualCog<ZipCode?>(nil)
/// ```
///
/// The final `Cog` suffix marks this as one keyless value reference; a narrower
/// role such as `Source` comes before it.
///
/// Constructing or copying a `ManualCog` does not create graph state. Its
/// stable descriptor identity names one app-lifetime state inside each
/// ``Cogs``; a test or preview context therefore receives isolated state,
/// while every copy used in the same context reaches the same source.
///
/// Manual state changes only through a ``Writer`` inside a named
/// ``Cogs/commit(_:_:)`` turn (or debug-only test seeding). A writer reads
/// that turn's staged value, while normal reads continue to see the latest
/// completed turn until the commit boundary. Multiple writes in one turn
/// collapse to the final staged value before equality and propagation.
///
/// Pass `name:` when `fileID:line` would be unclear in diagnostics or history.
/// Names do not define identity. The declaration and all graph access are
/// MainActor-isolated, allowing non-`Sendable` values to remain inside Cog.
@MainActor
public struct ManualCog<Value> {
  /// Stable declaration identity and behavior shared by reference copies.
  internal let descriptor: ManualCogDescriptor<Value>

  /// The keyed state this reference names, or `nil` for a keyless declaration.
  ///
  /// A `CogKey?`, whose physical layout `CogKey` chooses (perf §4). The type is not
  /// `@frozen`, so benchmarks may select another layout (perf §4, §9).
  internal let key: CogKey?

  /// Declares a source of state that starts at `startingValue`.
  ///
  /// This allocates one descriptor but no graph state. Each context creates its
  /// own state lazily and retains it until that context ends. Without an
  /// equality rule, every turn that writes the source counts as a change even
  /// if the old and final values happen to be equal.
  ///
  /// - Parameters:
  ///   - startingValue: The value a context's first read sees and retains until
  ///     a completed turn writes another value.
  ///   - lifetime: How long each of this declaration's states lives. Sources
  ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
  ///     release and reset with
  ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: Value,
    lifetime: ManualCogLifetime = .app,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: ManualCogDescriptor(
        startingValue: startingValue,
        equals: nil,
        lifetime: lifetime.stateLifetime,
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
  /// The comparison runs on the MainActor at the commit boundary.
  ///
  /// - Parameters:
  ///   - startingValue: The value reads see until something writes.
  ///   - equals: Comparison of the latest completed value and the turn's final
  ///     staged value. Return `true` to keep the old value and stop propagation.
  ///   - lifetime: How long each of this declaration's states lives. Sources
  ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
  ///     release and reset with
  ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: Value,
    equals: @escaping @MainActor (Value, Value) -> Bool,
    lifetime: ManualCogLifetime = .app,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: ManualCogDescriptor(
        startingValue: startingValue,
        equals: equals,
        lifetime: lifetime.stateLifetime,
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Builds a reference for an existing descriptor-and-key identity.
  ///
  /// ``ManualCogBox`` uses this path so repeated subscripting stays inert and
  /// lightweight. Context state is still created only when the reference is
  /// first read or written.
  internal init(descriptor: ManualCogDescriptor<Value>, key: CogKey?) {
    self.descriptor = descriptor
    self.key = key
  }
}

extension ManualCog where Value: Equatable {
  /// Declares an `Equatable` source whose equal writes are not changes.
  ///
  /// This overload is selected automatically when `Value` conforms to
  /// `Equatable`. Use ``init(_:equals:lifetime:name:fileID:line:)`` to substitute a
  /// domain-specific equality rule. Equality is applied once to the turn's
  /// final staged value, so equal writes and within-turn reversions produce no
  /// downstream work.
  ///
  /// - Parameters:
  ///   - startingValue: The initial app-lifetime value in each context.
  ///   - lifetime: How long each of this declaration's states lives. Sources
  ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
  ///     release and reset with
  ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
  ///   - name: The diagnostic and history label for this declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: Value,
    lifetime: ManualCogLifetime = .app,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: ManualCogDescriptor(
        startingValue: startingValue,
        equals: { oldValue, newValue in oldValue == newValue },
        lifetime: lifetime.stateLifetime,
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }
}
