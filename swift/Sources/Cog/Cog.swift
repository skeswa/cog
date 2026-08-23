/// A declaration and value reference for synchronously automatic state.
///
/// Declare one next to the state it summarizes, and write it as a plain
/// function of the cogs it reads:
///
/// ```swift
/// let isNiceOutsideHereCog = Cog<Bool> { c in
///   guard let currentZip = c[currentZipCog] else { return false }
///   let isNiceOutside = c[isNiceOutsideCogs[currentZip]]
///   return isNiceOutside
/// }
/// ```
///
/// The final `Cog` suffix marks the declaration itself as one keyless value
/// reference; bind each read to the corresponding unsuffixed domain name before
/// using it.
///
/// The selector reads through its ``Reader``. Each `c[valueReference]` records a
/// dependency, so changes can update this value. Reads from captured values,
/// globals, or stored properties are invisible to Cog.
///
/// Constructing or copying a `Cog` does not create graph state or run its
/// selector. The declaration carries stable descriptor identity; each
/// ``Cogs`` lazily creates its own cached state for that identity on first
/// read. Copies therefore name one state inside a context and independent state
/// in tests, previews, or other contexts. A diagnostic `name` labels the
/// declaration but never defines identity.
///
/// Later reads reuse the cached result until a dependency may have changed.
/// Cog settles those dependencies first, then reruns the selector only when
/// required. A tracked reaction keeps the `whileObserved` cog alive and its
/// final lease begins the context's grace period. Internal graph edges are
/// dependencies, not lifetime leases.
///
/// Keep selectors synchronous, cheap, and free of side effects. They may
/// branch or return early; each run replaces the dependency set. A selector
/// cannot `throw` in v1. Return `Result` for fallible domain work, or use an
/// `Cog.Async` when the work must await.
///
/// `Cog` and its selector are MainActor-isolated, so selectors may safely work
/// with non-`Sendable` values that remain inside the graph.
@MainActor
public struct Cog<Value> {
  /// Stable declaration identity and behavior shared by reference copies.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let descriptor: AutomaticCogDescriptor<Value>

  /// The keyed state this reference names, or `nil` for a keyless declaration.
  ///
  /// `CogKey` carries the erased key inline. The public reference stays
  /// resilient so this storage remains an implementation detail (perf §4).
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let key: CogKey?

  /// Declares one keyless value computed by `selector`.
  ///
  /// This allocates one descriptor. It creates no state and does not run
  /// `selector` (§2.3).
  ///
  /// - Parameters:
  ///   - selector: MainActor computation for the value. Reads through the
  ///     supplied ``Reader`` replace the dependency set on every run; other
  ///     reads are invisible to Cog.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ selector: @escaping @MainActor (Reader<Value>) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: AutomaticCogDescriptor(
        selector: { c, _ in selector(c) },
        equals: nil,
        lifetime: .whileObserved(grace: nil),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Declares an automatic value with an explicit equality rule.
  ///
  /// Cog calls `equals` after a rerun with the cached value and the newly
  /// computed value. Returning `true` keeps the cached value and stops the
  /// downstream wave; returning `false` publishes the new value and lets
  /// downstream cogs follow it. Equality does not skip a selector rerun that
  /// dependency settlement already required.
  ///
  /// - Parameters:
  ///   - selector: MainActor computation whose tracked reads become the next
  ///     dependency set.
  ///   - equals: MainActor comparison of the cached and newly computed values.
  ///     Return `true` to retain the cache and stop the downstream wave.
  ///   - name: What Cog should call this cog in diagnostics and debug history.
  ///     Defaults to the file and line of the declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ selector: @escaping @MainActor (Reader<Value>) -> Value,
    equals: @escaping @MainActor (Value, Value) -> Bool,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: AutomaticCogDescriptor(
        selector: { c, _ in selector(c) },
        equals: equals,
        lifetime: .whileObserved(grace: nil),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Builds a reference for an existing descriptor-and-key identity.
  ///
  /// ``CogBox`` and async value projections use this path so subscripting
  /// packages identity without allocating another descriptor or graph state.
  internal init(descriptor: AutomaticCogDescriptor<Value>, key: CogKey?) {
    self.descriptor = descriptor
    self.key = key
  }
}

extension Cog where Value: Equatable {
  /// Declares an `Equatable` automatic value whose equal reruns stop the wave.
  ///
  /// This overload is selected automatically when `Value` conforms to
  /// `Equatable`. Use ``init(_:equals:name:fileID:line:)`` to
  /// substitute a domain-specific equality rule. Equality affects downstream
  /// propagation after a required rerun; it does not change dependency
  /// tracking, identity, lifetime, or MainActor execution.
  ///
  /// - Parameters:
  ///   - selector: MainActor computation and dependency selection for the value.
  ///   - name: The diagnostic and history label for this declaration.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  public init(
    _ selector: @escaping @MainActor (Reader<Value>) -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line
  ) {
    self.init(
      descriptor: AutomaticCogDescriptor(
        selector: { c, _ in selector(c) },
        equals: { oldValue, newValue in oldValue == newValue },
        lifetime: .whileObserved(grace: nil),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }
}
