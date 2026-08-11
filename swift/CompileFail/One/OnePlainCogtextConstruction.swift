// scenario: ONE-03
//
// Feature code cannot build its own `Cogtext`. The initializer is `package`
// (§2.3), so the guard against a second graph is not a runtime check that
// application code has to remember — the name is simply not visible outside
// the package, and the mistake never compiles.
//
// This fixture is that boundary. It is type-checked as its own module with no
// `-package-name`, which is exactly the position an app that depends on Cog
// is in, and the two ways to spell plain construction both fail there.

import Cog

enum OnePlainCogtextConstruction {
  static func buildsItsOwnContext() -> Cogtext {
    // expect-error: 'Cogtext' initializer is inaccessible due to 'package' protection level
    Cogtext()
  }

  static func buildsItsOwnContextExplicitly() -> Cogtext {
    // expect-error: 'Cogtext' initializer is inaccessible due to 'package' protection level
    Cogtext.init()
  }
}
