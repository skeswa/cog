extension Cog {
  /// A declaration and value reference for one writable source of truth.
  ///
  /// Declare one at the top of the file that owns the state, and keep the
  /// declaration `private` so only that file can write it. Expose reads to
  /// everyone else, and put the ops that write it in the same file:
  ///
  /// ```swift
  /// private let _currentZipCog = Cog<ZipCode?>.Manual { nil }
  /// ```
  ///
  /// The final `Cog` suffix marks this as one keyless value reference, and the
  /// leading underscore marks the writable source; a `.readOnly` projection
  /// publishes the same name without the underscore.
  ///
  /// Constructing or copying a `Cog.Manual` does not create graph state. Its
  /// stable descriptor identity names one app-lifetime state inside each
  /// ``Cogs``; a test or preview context therefore receives isolated state,
  /// while every copy used in the same context reaches the same source.
  ///
  /// Manual state changes only through a ``Writer`` inside a named
  /// ``Cogs/turn(_:_:)`` turn (or debug-only test seeding). A writer reads
  /// that turn's staged value, while normal reads continue to see the latest
  /// completed turn until the turn boundary. Multiple writes in one turn
  /// collapse to the final staged value before equality and propagation.
  ///
  /// Pass `name:` when `fileID:line` would be unclear in diagnostics or history.
  /// Names do not define identity. MainActor isolation lets non-`Sendable`
  /// values remain inside Cog.
  @MainActor
  public struct Manual {
    /// Stable declaration identity and behavior shared by reference copies.
    #if !COG_ARENA_COMPACT
    @usableFromInline
    #endif
    internal let descriptor: ManualCogDescriptor<Value>

    /// The keyed state this reference names, or `nil` for a keyless declaration.
    ///
    /// `CogKey` carries the erased key inline. The public reference stays
    /// resilient so this storage remains an implementation detail (perf §4).
    #if !COG_ARENA_COMPACT
    @usableFromInline
    #endif
    internal let key: CogKey?

    /// Declares a source of state that starts at what `startingValue` returns.
    ///
    /// This allocates one descriptor but no graph state. Each context creates its
    /// own state lazily and retains it until that context ends. Without an
    /// equality rule, every turn that writes the source counts as a change even
    /// if the old and final values happen to be equal.
    ///
    /// The starting value is a closure rather than a value because one
    /// descriptor names every state this declaration ever has. A stored value
    /// would be handed to the app's context and to each test's context alike,
    /// so a `Value` that is or contains a reference type would give all of them
    /// one object to mutate. Cog runs the closure once per state instead, which
    /// is the only place a per-state value can be made.
    ///
    /// Keep it cheap and free of side effects. The app decides when a state
    /// first appears. Under
    /// ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``, it also
    /// decides how often the closure runs.
    /// It is an ordinary MainActor closure, receives no ``Reader``, and creates
    /// no dependencies.
    ///
    /// - Parameters:
    ///   - startingValue: Produces the value a state's first read sees and
    ///     retains until a completed turn writes another. Called once per
    ///     state.
    ///   - lifetime: How long each of this declaration's states lives. Sources
    ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
    ///     release and reset with
    ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
    ///   - name: What Cog should call this cog in diagnostics and debug history.
    ///     Defaults to the file and line of the declaration.
    ///   - fileID: The declaration's file. Leave this at its default.
    ///   - line: The declaration's line. Leave this at its default.
    public init(
      _ startingValue: @escaping @MainActor () -> Value,
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
    /// work; returning `false` publishes and propagates the new value. This also
    /// makes a change followed by a reversion in one turn count as no change.
    /// The comparison runs on the MainActor at the turn boundary.
    ///
    /// - Parameters:
    ///   - startingValue: Produces the value reads see until something writes.
    ///     Called once per state, for the reason the plain initializer gives.
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
      _ startingValue: @escaping @MainActor () -> Value,
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
    /// ``CogBox/Manual`` uses this path so repeated subscripting stays inert and
    /// lightweight. Context state is still created only when the reference is
    /// first read or written.
    internal init(descriptor: ManualCogDescriptor<Value>, key: CogKey?) {
      self.descriptor = descriptor
      self.key = key
    }
  }
}

extension Cog.Manual where Value: Equatable {
  /// Declares an `Equatable` source whose equal writes are not changes.
  ///
  /// This overload is selected automatically when `Value` conforms to
  /// `Equatable`. Use ``init(_:equals:lifetime:name:fileID:line:)`` to substitute a
  /// domain-specific equality rule. Equality is applied once to the turn's
  /// final staged value, so equal writes and within-turn reversions produce no
  /// downstream work.
  ///
  /// - Parameters:
  ///   - startingValue: Produces each context's initial app-lifetime value.
  ///     Called once per state, for the reason the plain initializer gives.
  ///   - lifetime: How long each of this declaration's states lives. Sources
  ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
  ///     release and reset with
  ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
  ///   - name: The diagnostic and history label for this declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: @escaping @MainActor () -> Value,
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
