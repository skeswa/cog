// scenario: ONE-03
//
// Feature code cannot build its own `Cogs`. The initializer is `package`,
// so the guard against a second graph is not a runtime check that
// application code has to remember — the name is simply not visible outside
// the package, and the mistake never compiles.
//
// This fixture is that boundary. It is type-checked as its own module with no
// `-package-name`, which is exactly the position an app that depends on Cog
// is in. `Cogs()` and `Cogs.init()` resolve to the same initializer, so one
// spelling carries the proof.

import Cog

enum OnePlainCogsConstruction {
  static func buildsItsOwnContext() -> Cogs {
    // expect-error: 'Cogs' initializer is inaccessible due to 'package' protection level
    Cogs()
  }
}
