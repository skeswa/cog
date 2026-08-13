// scenario: ASYNC-34
//
// An async cog always has a resting value, and a declaration that supplies
// none does not compile. The rejection is a deliberate diagnostic, not an
// opaque overload failure: an unavailable initializer catches the mistake and
// names both ways out — pass `default:`, or make the value `Optional` so it
// rests at `nil` through the library's one `CogDefaultable` conformance.
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
    // expect-error: an async cog needs a resting value
    _ = AsyncCog<Reading> { _ in .run { Reading() } }
  }

  /// A keyed declaration is rejected the same way.
  static func declaresKeyedWithoutADefault() {
    // expect-error: an async cog needs a resting value
    _ = AsyncCogBox<Reading, Int> { _, _ in .run { Reading() } }
  }

  /// Passing `default:` is one legal spelling.
  static func declaresWithAnExplicitDefault() {
    _ = AsyncCog<Reading>(default: Reading()) { _ in .run { Reading() } }
  }

  /// Resting an `Optional` at `nil` is the other.
  static func declaresAnOptionalRestingAtNil() {
    _ = AsyncCog<Reading?> { _ in .run { Reading() } }
  }
}
