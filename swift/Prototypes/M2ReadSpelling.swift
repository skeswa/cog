#if canImport(SwiftUI)
import SwiftUI

// M2-17a compares the three candidate spellings in otherwise identical view
// bodies. This prototype is deliberately outside every SwiftPM target; it
// exists to make the API choice reviewable before the real boundary exists.
//
// `cogs.get(reference)` wins. It says that the context performs a tracked
// read, matches `Reader.get` inside selectors, contrasts clearly with the
// one-shot `cogs.read`, and leaves subscript syntax to Writer's read/write
// staging. Making the reference callable would instead make an inert name
// appear to perform graph work and would require passing the context back to
// that name.

@MainActor
private struct PrototypeReference<Value> {
  let value: Value

  func callAsFunction(_ cogs: PrototypeContext) -> Value {
    cogs.get(self)
  }
}

@MainActor
private struct PrototypeContext {
  func get<Value>(_ reference: PrototypeReference<Value>) -> Value {
    reference.value
  }

  subscript<Value>(_ reference: PrototypeReference<Value>) -> Value {
    self.get(reference)
  }
}

@MainActor
private struct GetSpellingPrototype: View {
  let cogs: PrototypeContext
  let temperature: PrototypeReference<Int>

  var body: some View {
    Text("\(cogs.get(temperature)) degrees")
  }
}

@MainActor
private struct SubscriptSpellingPrototype: View {
  let cogs: PrototypeContext
  let temperature: PrototypeReference<Int>

  var body: some View {
    Text("\(cogs[temperature]) degrees")
  }
}

@MainActor
private struct CallableReferencePrototype: View {
  let cogs: PrototypeContext
  let temperature: PrototypeReference<Int>

  var body: some View {
    Text("\(temperature(cogs)) degrees")
  }
}
#endif
