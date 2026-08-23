// scenario: ASYNC-34
//
// An async cog always has a resting value, and a declaration that supplies
// none does not compile. The required argument makes the invariant visible at
// every declaration site, including when the value is optional.
//
// The legal spellings appear alongside the rejected one, so this fixture also
// proves the diagnostic is about the missing default rather than the
// declaration shape.

import Cog

enum AsyncCogWithoutDefaultRejected {
  /// A value type that cannot vouch for its own resting value.
  struct Reading: Equatable, Sendable {}

  /// A keyless declaration with no default and no conformance is rejected.
  static func declaresKeylessWithoutADefault() {
    // expect-error: missing argument for parameter 'default' in call
    _ = Cog<Reading>.Async { _ in .run { Reading() } }
  }

  /// A keyed declaration is rejected the same way.
  static func declaresKeyedWithoutADefault() {
    // expect-error: missing argument for parameter 'default' in call
    _ = CogBox<Reading, Int>.Async { _, _ in .run { Reading() } }
  }

  /// Passing `default:` is one legal spelling.
  static func declaresWithAnExplicitDefault() {
    _ = Cog<Reading>.Async(default: Reading()) { _ in .run { Reading() } }
  }

  /// An `Optional` states its resting `nil` explicitly too.
  static func declaresAnOptionalRestingAtNil() {
    _ = Cog<Reading?>.Async(default: nil) { _ in .run { Reading() } }
  }
}
