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
/// and it never has to be told which keys exist: `box[key]` builds a ref for
/// that key, and the app's one context creates a node the first time something
/// actually reads or writes it (§2.3). Ask for a thousand keys and you get a
/// thousand pieces of state; ask for none and the box costs one descriptor.
///
/// Each key is its own state. `box[90210]` and `box[10001]` start at the same
/// starting value and then go their own ways, because identity is the
/// declaration plus the key (§3.1) — writing one does not touch the other.
///
/// Building a ref is free. Every key shares the box's one descriptor, so
/// `box[key]` allocates nothing: it pairs that existing descriptor with the
/// key and hands back a value (perf §4, §9). Refs are meant to be built at the
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
  /// Declaring allocates one descriptor and nothing else. It creates no nodes
  /// and touches no context; the starting value is only what a key's node
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
  /// The closure runs once per key per context — when that key's node first
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

    self.descriptor = ManualCogDescriptor(
      startingValueForKey: { key in
        guard let key = key as? Key else {
          // `fatalError`, not `preconditionFailure`: the message is composed,
          // and an optimized `preconditionFailure` drops composed messages.
          fatalError(
            """
            A node of \(label) was asked to start at a value for \
            \(String(describing: key)), which is not a \(Key.self). Only this \
            box builds refs for its own declaration, so this context's node \
            storage is corrupt.
            """
          )
        }
        return startingValue(key)
      },
      label: label
    )
  }

  /// The ref naming this box's state for one key.
  ///
  /// Building the same key twice gives two equivalent refs, not two pieces of
  /// state: `box[5]` here and `box[5]` in another file resolve to one node, so
  /// a write through either is a write both can see. `box[6]` is a different
  /// node entirely.
  ///
  /// This is a value, and building it is not a lookup — nothing is searched,
  /// created, or registered until a context is asked to resolve the ref. That
  /// is why it is safe to write `box[key]` inline at every call site.
  ///
  /// - Parameter key: Which of this declaration's values to name.
  /// - Returns: A ref for that key, usable anywhere a ``ManualCog`` is.
  public subscript(key: Key) -> ManualCog<Value> {
    ManualCog(descriptor: descriptor, key: key)
  }
}
