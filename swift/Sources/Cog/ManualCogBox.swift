/// A writable source of state, one value per key.
///
/// Use a box when a source has one value per key, such as a zip code or
/// document ID. Keep the box `fileprivate` (or `private` inside a type) so only
/// its owner can write it:
///
/// ```swift
/// fileprivate let weatherReportSource = ManualCogBox<Weather?, ZipCode>(nil)
/// ```
///
/// The box holds no keys or values. `box[key]` builds a value reference, and
/// the context creates that key's state on first use. If an app uses 1,000
/// keys, the context creates 1,000 states. An unused box costs one descriptor.
///
/// Each key has separate state. Writing `box[90210]` does not change
/// `box[10001]`.
///
/// Building `box[key]` creates no graph state or descriptor. It is cheap to use
/// inline, as in `c.get(weatherReport[zip])`.
///
/// Keys may be any `Hashable` type. Prefer a small domain type such as
/// `ZipCode` or `Document.ID` over `String` or `Int`. Cog stores keys as
/// `AnyHashable`; keys larger than three words may allocate.
@MainActor
public struct ManualCogBox<Value, Key: Hashable> {
  /// The one declaration behind every key of this box.
  ///
  /// The box shares this descriptor across all keys.
  internal let descriptor: ManualCogDescriptor<Value>

  /// Declares a keyed source whose every key starts at `startingValue`.
  ///
  /// This allocates one descriptor. A context creates each key's state on
  /// first use.
  ///
  /// ```swift
  /// fileprivate let heatAdvisorySource = ManualCogBox<Bool, ZipCode>(false)
  /// ```
  ///
  /// One value stands behind every key, so a `Value` that is a reference type
  /// hands every key the same object. Use the closure form below when each key
  /// should start at its own value.
  ///
  /// - Parameters:
  ///   - startingValue: The value a key's reads see until something writes it.
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
    self.descriptor = ManualCogDescriptor(
      startingValue: startingValue,
      equals: nil,
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// Declares a keyed source with one starting value and an explicit equality
  /// rule shared by every key.
  ///
  /// Cog compares each written key's latest completed value with that turn's
  /// final staged value. Returning `true` suppresses downstream work for that
  /// key and does not affect any sibling key.
  public init(
    _ startingValue: Value,
    equals: @escaping @MainActor (Value, Value) -> Bool,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = ManualCogDescriptor(
      startingValue: startingValue,
      equals: equals,
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// Declares a keyed source whose keys each start at a value computed from
  /// the key.
  ///
  /// ```swift
  /// fileprivate let cartSource = ManualCogBox<Cart, UserID> { user in
  ///   Cart(owner: user)
  /// }
  /// ```
  ///
  /// The closure runs once for each key used in a context. A write replaces
  /// its result. Use `CogBox` when the value should track other state.
  ///
  /// Keep the closure cheap and free of side effects. The app controls when
  /// each key first appears.
  ///
  /// If `Value` is a function from `Key`, disambiguate the constant form with
  /// its type: `ManualCogBox<(UserID) -> Cart, UserID>(makeCart)`.
  ///
  /// - Parameters:
  ///   - startingValue: What a key's reads see until something writes that
  ///     key.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ startingValue: @escaping @MainActor (Key) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)

    self.descriptor = Self.makeDescriptor(
      startingValue: startingValue,
      equals: nil,
      label: label
    )
  }

  /// Declares a keyed source with per-key starting values and an explicit
  /// equality rule shared by every key.
  public init(
    _ startingValue: @escaping @MainActor (Key) -> Value,
    equals: @escaping @MainActor (Value, Value) -> Bool,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      startingValue: startingValue,
      equals: equals,
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// The value reference naming this box's state for one key.
  ///
  /// Equal keys name the same state. A context resolves or creates that state
  /// when the reference is first read or written.
  ///
  /// - Parameter key: Which of this declaration's values to name.
  /// - Returns: A value reference for that key, usable anywhere a ``ManualCog`` is.
  public subscript(key: Key) -> ManualCog<Value> {
    ManualCog(descriptor: descriptor, key: key)
  }

  /// Builds the descriptor shared by the per-key initializer overloads.
  private static func makeDescriptor(
    startingValue: @escaping @MainActor (Key) -> Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    label: CogLabel
  ) -> ManualCogDescriptor<Value> {
    ManualCogDescriptor(
      startingValueForKey: { key in
        guard let key = key as? Key else {
          // `fatalError`, not `preconditionFailure`: the message is composed,
          // and an optimized `preconditionFailure` drops composed messages.
          fatalError(
            """
            A state of \(label) was asked to start at a value for \
            \(String(describing: key)), which is not a \(Key.self). Only this \
            box builds value references for its own declaration, so this context's state \
            storage is corrupt.
            """
          )
        }
        return startingValue(key)
      },
      equals: equals,
      label: label
    )
  }
}

extension ManualCogBox where Value: Equatable {
  /// Declares an `Equatable` keyed source with one starting value.
  ///
  /// This overload is selected automatically and makes equal writes no-ops.
  public init(
    _ startingValue: Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = ManualCogDescriptor(
      startingValue: startingValue,
      equals: { oldValue, newValue in oldValue == newValue },
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }

  /// Declares an `Equatable` keyed source with per-key starting values.
  ///
  /// This overload is selected automatically and makes equal writes no-ops.
  public init(
    _ startingValue: @escaping @MainActor (Key) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.descriptor = Self.makeDescriptor(
      startingValue: startingValue,
      equals: { oldValue, newValue in oldValue == newValue },
      label: CogLabel(name: name, fileID: fileID, line: line)
    )
  }
}
