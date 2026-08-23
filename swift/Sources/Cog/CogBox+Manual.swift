extension CogBox {
  /// A family of writable sources sharing one declaration, one value per key.
  ///
  /// Use a box when a source has one value per key, such as a zip code or
  /// document ID. Keep the box `private` so only its owner can write it:
  ///
  /// ```swift
  /// private let _weatherReportCogs = CogBox<Weather?, ZipCode>.Manual(nil)
  /// ```
  ///
  /// The plural final `Cogs` suffix marks this as a box that can produce many
  /// keyed value references.
  ///
  /// The box holds no keys or values. `box[key]` builds a value reference, and
  /// the context creates that key's state on first use. If an app uses 1,000
  /// keys, the context creates 1,000 states. An unused box costs one descriptor.
  ///
  /// Descriptor identity plus the hashable key names state. Equal keys reach the
  /// same source in one context; unequal keys have independent values and
  /// propagation. Copies of a box retain descriptor identity, while separate box
  /// declarations remain distinct even for equal keys. Another context creates
  /// its own state for every demanded key.
  ///
  /// Building `box[key]` creates no graph state or descriptor. It is cheap to form
  /// at the read site and unwrap into its domain local, as in
  /// `let weatherReport = c[weatherReportCogs[zip]]`.
  ///
  /// Each demanded key has app lifetime in its context, like ``Cog/Manual``.
  /// Writes occur through ``Writer`` inside turns and equality is applied only to
  /// the written key's old and final staged values. The box and its starting-value
  /// closure are MainActor-isolated.
  ///
  /// Keys may be any `Hashable` type. Prefer a small domain type such as
  /// `ZipCode` or `Document.ID` over `String` or `Int`. A value reference stores
  /// its key inline as `AnyHashable` (perf §4).
  @MainActor
  public struct Manual {
    /// Stable declaration identity and behavior shared by every key and box copy.
    internal let descriptor: ManualCogDescriptor<Value>

    /// Declares a keyed source whose every key starts at `startingValue`.
    ///
    /// This allocates one descriptor. A context creates each key's state on
    /// first use.
    ///
    /// ```swift
    /// private let _heatAdvisoryCogs = CogBox<Bool, ZipCode>.Manual(false)
    /// ```
    ///
    /// One value stands behind every key, so a `Value` that is a reference type
    /// hands every key the same object. Use the closure form below when each key
    /// should start at its own value.
    ///
    /// Without an equality rule, a written key always propagates at the turn
    /// boundary. The `Equatable` overload or explicit comparison can make equal
    /// writes no-ops.
    ///
    /// - Parameters:
    ///   - startingValue: The value a key's reads see until something writes it.
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
      self.descriptor = ManualCogDescriptor(
        startingValue: startingValue,
        equals: nil,
        lifetime: lifetime.stateLifetime,
        label: CogLabel(name: name, fileID: fileID, line: line)
      )
    }

    /// Declares a keyed source with one starting value and an explicit equality
    /// rule shared by every key.
    ///
    /// Cog compares each written key's latest completed value with that turn's
    /// final staged value. Returning `true` suppresses downstream work for that
    /// key and does not affect any sibling key.
    ///
    /// - Parameters:
    ///   - startingValue: The shared initial value installed lazily for every key.
    ///   - equals: MainActor comparison for the old and final staged value of a
    ///     written key. Return `true` to keep the old value.
    ///   - lifetime: How long each of this declaration's states lives. Sources
    ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
    ///     release and reset with
    ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
    ///   - name: The diagnostic and history label for the keyed declaration.
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
      self.descriptor = ManualCogDescriptor(
        startingValue: startingValue,
        equals: equals,
        lifetime: lifetime.stateLifetime,
        label: CogLabel(name: name, fileID: fileID, line: line)
      )
    }

    /// Declares a keyed source whose keys each start at a value computed from
    /// the key.
    ///
    /// ```swift
    /// private let _cartCogs = CogBox<Cart, UserID>.Manual { user in
    ///   Cart(owner: user)
    /// }
    /// ```
    ///
    /// The closure runs once for each key used in a context. A write replaces
    /// its result. Use `CogBox` when the value should track other state.
    ///
    /// Keep the closure cheap and free of side effects. The app controls when
    /// each key first appears. Reads inside this closure are ordinary Swift reads;
    /// it receives no ``Reader`` and creates no dependencies.
    ///
    /// If `Value` is a function from `Key`, disambiguate the constant form with
    /// its type: `CogBox<(UserID) ->.Manual Cart, UserID>(makeCart)`.
    ///
    /// - Parameters:
    ///   - startingValue: What a key's reads see until something writes that
    ///     key.
    ///   - lifetime: How long each of this declaration's states lives. Sources
    ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
    ///     release and reset with
    ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
    ///   - name: What Cog should call this cog in diagnostics and debug history.
    ///     Defaults to the file and line of the declaration.
    ///   - fileID: The declaration's file. Leave this at its default.
    ///   - line: The declaration's line. Leave this at its default.
    public init(
      _ startingValue: @escaping @MainActor (Key) -> Value,
      lifetime: ManualCogLifetime = .app,
      name: String? = nil,
      fileID: StaticString = #fileID,
      line: UInt = #line
    ) {
      let label = CogLabel(name: name, fileID: fileID, line: line)

      self.descriptor = Self.makeDescriptor(
        startingValue: startingValue,
        equals: nil,
        lifetime: lifetime.stateLifetime,
        label: label
      )
    }

    /// Declares a keyed source with per-key starting values and an explicit
    /// equality rule shared by every key.
    ///
    /// The starting closure runs once per key and context, before that key's
    /// first read or write. The equality closure runs only at a turn boundary for
    /// a written key; sibling states remain untouched.
    ///
    /// - Parameters:
    ///   - startingValue: MainActor factory for a key's initial value.
    ///   - equals: MainActor comparison of that key's latest completed and final
    ///     staged values.
    ///   - lifetime: How long each of this declaration's states lives. Sources
    ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
    ///     release and reset with
    ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
    ///   - name: The diagnostic and history label for the keyed declaration.
    ///   - fileID: The declaration's file. Leave this at its default.
    ///   - line: The declaration's line. Leave this at its default.
    public init(
      _ startingValue: @escaping @MainActor (Key) -> Value,
      equals: @escaping @MainActor (Value, Value) -> Bool,
      lifetime: ManualCogLifetime = .app,
      name: String? = nil,
      fileID: StaticString = #fileID,
      line: UInt = #line
    ) {
      self.descriptor = Self.makeDescriptor(
        startingValue: startingValue,
        equals: equals,
        lifetime: lifetime.stateLifetime,
        label: CogLabel(name: name, fileID: fileID, line: line)
      )
    }

    /// The value reference naming this box's state for one key.
    ///
    /// Equal keys name the same state. A context resolves or creates that state
    /// when the reference is first read or written.
    /// Subscripting allocates no descriptor and does not run the starting-value
    /// closure.
    ///
    /// - Parameter key: Which of this declaration's values to name.
    /// - Returns: A writable value reference for that key.
    public subscript(key: Key) -> Cog<Value>.Manual {
      Cog.Manual(descriptor: descriptor, key: CogKey(key))
    }

    /// Builds the descriptor shared by the per-key initializer overloads.
    ///
    /// Key erasure stays behind this boundary so public value references remain
    /// lightweight. The checked cast diagnoses an impossible descriptor/key
    /// mismatch as storage corruption instead of silently reading another state.
    private static func makeDescriptor(
      startingValue: @escaping @MainActor (Key) -> Value,
      equals: (@MainActor (Value, Value) -> Bool)?,
      lifetime: CogStateLifetime,
      label: CogLabel
    ) -> ManualCogDescriptor<Value> {
      ManualCogDescriptor(
        startingValueForKey: { erasedKey in
          guard let key = erasedKey?.erased.base as? Key else {
            // `fatalError`, not `preconditionFailure`: the message is composed,
            // and an optimized `preconditionFailure` drops composed messages.
            fatalError(
              """
              A state of \(label) was asked to start at a value for \
              \(String(describing: erasedKey?.erased)), which is not a \(Key.self). Only this \
              box builds value references for its own declaration, so this context's state \
              storage is corrupt.
              """
            )
          }
          return startingValue(key)
        },
        equals: equals,
        lifetime: lifetime,
        label: label
      )
    }
  }
}

extension CogBox.Manual where Value: Equatable {
  /// Declares an `Equatable` keyed source with one starting value.
  ///
  /// This overload is selected automatically and makes equal final writes
  /// no-ops independently for each key. A reference-type starting value is
  /// still shared across keys; use the closure overload for distinct objects.
  ///
  /// - Parameters:
  ///   - startingValue: The initial value shared by all lazily created keys.
  ///   - lifetime: How long each of this declaration's states lives. Sources
  ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
  ///     release and reset with
  ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
  ///   - name: The diagnostic and history label for the keyed declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: Value,
    lifetime: ManualCogLifetime = .app,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = ManualCogDescriptor(
      startingValue: startingValue,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: lifetime.stateLifetime,
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// Declares an `Equatable` keyed source with per-key starting values.
  ///
  /// This overload is selected automatically, runs `startingValue` once per
  /// key and context, and makes equal final writes no-ops for that key.
  ///
  /// - Parameters:
  ///   - startingValue: MainActor factory for each key's initial value.
  ///   - lifetime: How long each of this declaration's states lives. Sources
  ///     default to ``ManualCogLifetime/app``; an ephemeral source opts into
  ///     release and reset with
  ///     ``ManualCogLifetime/whileObserved(resetToInitial:grace:)``.
  ///   - name: The diagnostic and history label for the keyed declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: @escaping @MainActor (Key) -> Value,
    lifetime: ManualCogLifetime = .app,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      startingValue: startingValue,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: lifetime.stateLifetime,
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }
}
