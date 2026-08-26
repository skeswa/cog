# Testing

_August 26, 2026_

Tests and previews are separate app runtimes. Each may create one isolated
`Cogs`, and everything the handbook's other chapters set up — sources behind
ops, capabilities injected into mechanisms, clocks stored not hard-coded —
exists so that this chapter's tests stay short.

## One isolated runtime per test

Test targets depend on `CogTesting`. Each test creates one runtime and must
not fragment state inside it — the singular-state rule applies within the
test's world just as it does in production:

```swift
import Cog
import CogTesting
import Testing

@MainActor
@Test func reselectingTheTabPopsToRoot() {
  let cogs = Cogs.forTesting()

  cogs.selectTab(.explore)
  cogs.show(.region(RegionID(rawValue: "silver-coast")))
  cogs.selectTab(.explore)

  #expect(cogs.peek(tabPathCogs[.explore]) == [])
}
```

The pattern above is the workhorse: drive the state layer through the same
named ops production calls, assert through `peek`. Because ops, deep-link
parsing, navigation, and derived state never touch SwiftUI, they all test
headlessly this way.

## Seeding versus mechanisms

`Cogs.forTesting(seeding:mechanisms:)` offers two distinct tools; they are not
interchangeable:

- **`seeding:`** installs values with no turn, no notice, and no reaction,
  before mechanisms start. Use it to place the world in a starting position
  cheaply. It has no production counterpart, and must not become one in
  spirit — it is not how a test exercises initial-state logic.
- **`mechanisms:`** runs the same mechanisms production assembles. Use it when
  the mechanism itself — restoration, a reaction, a gated scope — is the
  subject, passing test doubles for its capabilities:

```swift
var saved: [TrailSnapshot] = []
let cogs = Cogs.forTesting(mechanisms: [
  TrailPersistenceMechanism(
    store: TrailStore(load: { nil }, save: { saved.append($0) })
  )
])
```

Injected capability structs with closure fields (`TrailStore`,
`WeatherService`) are what make this cheap: the test replaces behavior without
mocking frameworks, and the mechanism under test is the production type.

## Time is injected

Timed behavior sleeps on the clock its mechanism stores, so tests pass a
controlled clock and advance it explicitly rather than sleeping and guessing.
Use `TestClock` both for code that schedules work and — as
`Cogs.forTesting(clock:)` — when testing Cog's own lifetime grace period.
Behavior tests never depend on timing guesses.

## Views under test and preview

Host a view under the same environment modifier production uses:

```swift
TrailDetailScreen(trailID: trailID)
  .cogEnvironment(cogs)
```

Previews follow the identical pattern with a preview-local
`Cogs.forTesting()`. Do not create a second runtime inside the same test or
preview tree.

## Assembly tests only

`Cogs.withAssembledCogs` exists for tests whose _subject_ is production
assembly and installation. Its closure is synchronous and cannot nest; it is
not normal test setup — `forTesting` is.

## What the examples leave open

The example apps ship without test targets today; the patterns above are the
shapes their state layers were built to support. When adding tests to an app,
start where the graph does the most work per line of test: ops that compose
turns, deep-link round trips, and mechanisms with injected capabilities.
