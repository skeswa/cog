// scenario: DECL-12
//
// An automatic Cog's selector is synchronous and nonthrowing in v1. The valid
// declaration first proves this fixture resolved the real public initializer;
// the otherwise-identical throwing function must fail at that initializer's
// type boundary.
//
// Named functions are deliberate. A closure literal inferred in a nonthrowing
// context can instead diagnose the `throw` inside its body. Giving the
// forbidden selector an explicit throwing type makes the one error describe
// the API restriction this scenario owns.

import Cog

enum ThrowingSelectorRejected {
  nonisolated struct Value {}

  nonisolated enum Failure: Error {
    case expected
  }

  static func synchronousSelector(_: Reader<Value>) -> Value {
    Value()
  }

  static func throwingSelector(_: Reader<Value>) throws -> Value {
    throw Failure.expected
  }

  static func declaresSelectors() {
    _ = Cog<Value>(synchronousSelector)

    // expect-error: invalid conversion from throwing function of type
    _ = Cog<Value>(throwingSelector)
  }
}
