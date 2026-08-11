// scenario: HARNESS-01
//
// Sentinel. Proves the batched compile-fail harness reports an ordinary
// semantic error, and that two expectations in one fixture are both matched
// against their own lines.
//
// `HARNESS-*` is the reserved prefix for fixtures that prove the harness
// itself rather than a scenario in docs/swift/impl/scenarios.md. The fixture
// contract lives at the top of tools/check-compile-fail.mjs.

enum HarnessLetAssignment {
  static func assignsToALetConstant() {
    let value = 1
    // expect-error: cannot assign to value: 'value' is a 'let' constant
    value = 2
    _ = value
  }

  static func returnsTheWrongType() -> Int {
    let text = "not an Int"
    // expect-error: cannot convert return expression of type 'String' to return type 'Int'
    return text
  }
}
