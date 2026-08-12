/// A writable source of state, one value per key.
///
/// Declare one where you would declare a ``ManualCog`` but the state is
/// per-something — per zip code, per document, per row — and keep it
/// `fileprivate` (or `private` inside a type) so only that file can write it
/// (§4):
///
/// ```swift
/// fileprivate let weatherReportSource = ManualCogBox<Weather?, ZipCode>(nil)
/// ```
///
/// A box is a declaration, not a collection. It holds no values and no keys,
/// and it never has to be told which keys exist: `box[key]` builds a value reference for
/// that key, and the app's one context creates a state the first time something
/// actually reads or writes it (§2.3). Ask for a thousand keys and you get a
/// thousand pieces of state; ask for none and the box costs one descriptor.
///
/// Each key is its own state. `box[90210]` and `box[10001]` start at the same
/// starting value and then go their own ways, because identity is the
/// declaration plus the key (§3.1) — writing one does not touch the other.
///
/// Building a value reference is free. Every key shares the box's one descriptor, so
/// `box[key]` allocates nothing: it pairs that existing descriptor with the
/// key and hands back a value (perf §4, §9). Value references are meant to be built at the
/// point of use rather than stashed — `c.get(weatherReport[zip])` inside a
/// selector is the normal spelling, and the key reaches it by ordinary lexical
/// capture, with no hidden key flow.
///
/// A key can be anything `Hashable`. Prefer a domain type — `ZipCode`,
/// `Document.ID` — over a bare `String` or `Int`, so that two boxes keyed by
/// different things cannot be confused at a call site. Prefer a small one,
/// too: the correctness build carries the key inline as an `AnyHashable`,
/// which is free for a key of up to three words and boxes anything larger. A
/// key is an identity, so a small identifier is usually the right shape
/// anyway.
@MainActor
public struct ManualCogBox<Value, Key: Hashable> {
  /// The one declaration behind every key of this box.
  ///
  /// One descriptor, not one per key: this is what makes ``subscript(_:)``
  /// allocation-free, and what lets a box be declared before anyone knows
  /// which keys an app will use.
  internal let descriptor: ManualCogDescriptor<Value>

  /// Declares a keyed source whose every key starts at `startingValue`.
  ///
  /// Declaring allocates one descriptor and nothing else. It creates no states
  /// and touches no context; the starting value is only what a key's state
  /// begins at, whenever one is first needed.
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
  /// The closure runs once per key per context — when that key's state first
  /// appears — and never again for that key. It is a *starting* value, so a
  /// write replaces it permanently; nothing recomputes it, and it is not a
  /// derived cog. Reach for `CogBox` when the value should keep tracking
  /// something else.
  ///
  /// Keep the closure cheap and free of side effects. Which keys are asked
  /// for, and when, is up to the app, so a starting-value closure is not a
  /// place to load, log, or count anything.
  ///
  /// When `Value` is itself a function type taking `Key`, a closure literal
  /// could satisfy either initializer. Say which you mean by naming the
  /// constant form's type — `ManualCogBox<(UserID) -> Cart, UserID>(makeCart)`
  /// — rather than passing a bare literal.
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
  /// Building the same key twice gives two equivalent value references, not two pieces of
  /// state: `box[5]` here and `box[5]` in another file resolve to one state, so
  /// a write through either is a write both can see. `box[6]` is a different
  /// state entirely.
  ///
  /// This is a value, and building it is not a lookup — nothing is searched,
  /// created, or registered until a context is asked to resolve the value reference. That
  /// is why it is safe to write `box[key]` inline at every call site.
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
