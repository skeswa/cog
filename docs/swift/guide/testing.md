# Testing

_August 26, 2026_

Tests and previews are separate app runtimes. Each one may create one
isolated `Cogs`. Everything the other chapters set up — sources behind ops,
capabilities injected into mechanisms, clocks stored rather than hard-coded
— exists so that this chapter's tests stay short.

## One isolated runtime per test

Test targets depend on `CogTesting`. Each test creates one runtime, and must
not split state up inside it. The singular-state rule applies inside a
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
named ops production calls, then assert through `peek`. Ops, deep-link
parsing, navigation, and derived state never touch SwiftUI, so they all test
this way — no UI involved.

## Seeding versus mechanisms

`Cogs.forTesting(seeding:mechanisms:)` offers two different tools. They are
not interchangeable:

- **`seeding:`** installs values with no turn, no notice, and no reaction,
  before mechanisms start. Use it to place the world in a starting position
  cheaply. It has no production counterpart, and it is not how a test
  exercises initial-state logic.
- **`mechanisms:`** runs the same mechanisms production assembles. Use it
  when the mechanism itself — restoration, a reaction, a gated scope — is
  the thing under test. Pass test doubles for its capabilities:

```swift
var saved: [TrailSnapshot] = []
let cogs = Cogs.forTesting(mechanisms: [
  TrailPersistenceMechanism(
    store: TrailStore(load: { nil }, save: { saved.append($0) })
  )
])
```

Injected capability structs with closure fields (`TrailStore`,
`WeatherService`) are what make this cheap. The test swaps behavior without
any mocking framework, and the mechanism under test is the production type.

## Time is injected

Timed behavior sleeps on the clock its mechanism stores. A test passes a
controlled clock and advances it explicitly, instead of sleeping and hoping.
Use `TestClock` both for code that schedules work and — as
`Cogs.forTesting(clock:)` — when testing Cog's own lifetime grace period.
Behavior tests never depend on timing guesses.

## Views under test and preview

Host a view under the same environment modifier production uses:

```swift
TrailDetailScreen(trailID: trailID)
  .cogEnvironment(cogs)
```

Previews follow the same pattern with a preview-local `Cogs.forTesting()`.
Do not create a second runtime inside the same test or preview tree.

## Assembly tests only

`Cogs.withAssembledCogs` exists for tests whose _subject_ is production
assembly and installation. Its closure is synchronous and cannot nest. It is
not normal test setup — `forTesting` is.

## What the examples leave open

The example apps ship without test targets today. The patterns above are the
shapes their state layers were built to support. When you add tests to an
app, start where the graph does the most work per line of test: ops that
compose turns, deep-link round trips, and mechanisms with injected
capabilities.
