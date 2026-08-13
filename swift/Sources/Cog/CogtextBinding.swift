public import SwiftUI

extension Cogtext {
  /// Builds a domain binding whose reads track this source and whose writes
  /// enter the graph through the supplied turn body.
  ///
  /// Keep writable sources private to their state file and expose bindings
  /// from that file. The default turn name is the property or method that
  /// creates the binding.
  ///
  /// SwiftUI evaluates the getter through the context's tracked UI subscript,
  /// pinning the exact manual state to this app context and registering
  /// Observation access. The setter opens a fresh named turn and hands domain
  /// code a ``Writer`` plus SwiftUI's proposed value; it does not expose the
  /// source automatically to callers.
  ///
  /// - Parameters:
  ///   - valueReference: The writable source used by the tracked getter.
  ///   - name: The turn name for each setter invocation.
  ///   - set: Domain write logic executed synchronously inside that turn.
  /// - Returns: A MainActor SwiftUI binding backed by this context.
  public func binding<Value>(
    for valueReference: ManualCog<Value>,
    name: String = #function,
    set: @escaping @MainActor (Writer, Value) -> Void
  ) -> Binding<Value> {
    makeBinding(name: name, read: { self[valueReference] }, set: set)
  }

  /// Builds a domain binding whose tracked getter reads a derived cog.
  ///
  /// The getter settles and observes `valueReference`. Because a derived cog
  /// is not writable, the setter receives the proposed value inside a new
  /// named turn and must translate it into writes to owned manual sources.
  ///
  /// - Parameters:
  ///   - valueReference: The derived value rendered by the getter.
  ///   - name: The turn name for each setter invocation.
  ///   - set: Domain logic mapping the proposed value to manual-source writes.
  /// - Returns: A binding whose reads participate in SwiftUI Observation.
  public func binding<Value>(
    for valueReference: Cog<Value>,
    name: String = #function,
    set: @escaping @MainActor (Writer, Value) -> Void
  ) -> Binding<Value> {
    makeBinding(name: name, read: { self[valueReference] }, set: set)
  }

  /// Builds a domain binding without exposing the projection's writable
  /// source.
  ///
  /// The getter tracks the projection's underlying manual state. The setter is
  /// supplied by the state-owning file and runs inside a named turn, preserving
  /// compile-time write encapsulation for outside callers.
  ///
  /// - Parameters:
  ///   - valueReference: The public read-only source projection.
  ///   - name: The turn name for each setter invocation.
  ///   - set: Owner-provided write logic for the proposed value.
  /// - Returns: A binding that exposes no writable Cog reference.
  public func binding<Value>(
    for valueReference: CogProjection<Value>,
    name: String = #function,
    set: @escaping @MainActor (Writer, Value) -> Void
  ) -> Binding<Value> {
    makeBinding(name: name, read: { self[valueReference] }, set: set)
  }

  /// Shares the tracked getter and named-turn setter mechanics across overloads.
  private func makeBinding<Value>(
    name: String,
    read: @escaping @MainActor () -> Value,
    set: @escaping @MainActor (Writer, Value) -> Void
  ) -> Binding<Value> {
    Binding(
      get: read,
      set: { value in
        self.commit(name) { c in
          set(c, value)
        }
      }
    )
  }
}
