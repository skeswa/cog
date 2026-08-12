public import SwiftUI

extension Cogtext {
  /// Builds a domain binding whose reads track this source and whose writes
  /// enter the graph through the supplied turn body.
  ///
  /// Keep writable sources private to their state file and expose bindings
  /// from that file. The default turn name is the property or method that
  /// creates the binding.
  public func binding<Value>(
    for valueReference: ManualCog<Value>,
    name: String = #function,
    set: @escaping @MainActor (Writer, Value) -> Void
  ) -> Binding<Value> {
    makeBinding(name: name, read: { self.get(valueReference) }, set: set)
  }

  /// Builds a domain binding whose getter reads a derived cog.
  public func binding<Value>(
    for valueReference: Cog<Value>,
    name: String = #function,
    set: @escaping @MainActor (Writer, Value) -> Void
  ) -> Binding<Value> {
    makeBinding(name: name, read: { self.get(valueReference) }, set: set)
  }

  /// Builds a domain binding without exposing the projection's writable
  /// source.
  public func binding<Value>(
    for valueReference: CogProjection<Value>,
    name: String = #function,
    set: @escaping @MainActor (Writer, Value) -> Void
  ) -> Binding<Value> {
    makeBinding(name: name, read: { self.get(valueReference) }, set: set)
  }

  private func makeBinding<Value>(
    name: String,
    read: @escaping @MainActor () -> Value,
    set: @escaping @MainActor (Writer, Value) -> Void
  ) -> Binding<Value> {
    Binding(
      get: read,
      set: { value in
        self.commit(name) { writer in
          set(writer, value)
        }
      }
    )
  }
}
