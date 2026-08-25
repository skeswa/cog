# The plain-Swift Storefront comparison runtimes

A separate SwiftPM package named `cog-storefront-observation`. It sits beside
the Cog and swift-state-graph runtime packages and depends only on the neutral
Storefront workload.

It holds two of the four runtimes the Storefront macrobenchmark compares, both
written over plain Swift Observation with no Cog symbol anywhere in them:

| Target                      | Benchmark slug     | What it is                                                                                                                     |
| --------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `StorefrontObservationRaw`  | `observation-raw`  | The floor. Recomputes every derived value on every read, caches nothing, and invalidates nothing.                              |
| `StorefrontObservationMemo` | `observation-memo` | Honest hand-written memoization over the same primitives: what a careful team would actually write, and what writing it costs. |

Both run the identical eleven-phase interaction trace from `StorefrontWorkload`,
against the identical fixtures, the identical scripted request boundary, and the
identical shadow model. That is the point of the whole arrangement: two runtimes
exercising two similar-looking sessions would let a result differ without either
being wrong.

## Why the two ports are two targets

Not tidiness — fairness. Two separate targets make it a **compile error** for the
raw port to reach the memo port's cache, which is the single most likely way this
comparison could quietly become dishonest. One target with two types inside it
would leave that door open and rely on reviewer attention to keep it shut.

## Why this is not part of `cog-storefront`

Two reasons, in order of weight.

First, CogLint runs `swift/Benchmarks/Storefront/Runtimes/CogRuntime/Sources` under
`--target-role production`, which applies the Cog **application** ruleset — `manual-cog-underscore` and the
`Cog`/`Cogs` suffix conventions — to everything under that path. A target whose
entire point is to contain no Cog would be linted as Cog application code, and
the fix for that must never be to weaken a rule the library ships to real
consumers.

Second, `cog-storefront` is the package an application developer may one day be
pointed at as the worked large-app example. It should contain the Cog way of
building this app, not three alternatives to it.

## Why this is not the package the state-graph port lives in

Because SwiftPM hands a package's dependencies to everyone who resolves it. The
swift-state-graph port is in `swift/Benchmarks/Storefront/Runtimes/StateGraph` so
that an `@Observable` comparison application can link a port from here without
resolving swift-state-graph and its macro toolchain. That is the identical
mistake [`Workload/README.md`](../../Workload/README.md) documents about
the `cog-benchmarks` **package**.

## Why it stays independent of the runner

`swift/Benchmarks/Runner` owns the ordo-one harness and malloc interposer. This
package does not: the runner consumes these products through a path dependency,
while an eventual Observation benchmark application can resolve them without
pulling measurement infrastructure or swift-state-graph into its graph.

## Dependencies

Exactly one, by path:

```swift
dependencies: [
  .package(path: "../../Workload")
]
```

Nothing else. The path is a path and never a version, for the reason
`swift/Benchmarks/Runner/README.md` records: a measurement resolved from a tag is a
statement about a turn that is not the one being changed.

## Build settings

`storefrontSwiftSettings` in `Package.swift` is copied **verbatim** from
`swift/Benchmarks/Storefront/Workload/Package.swift` and must stay
byte-identical to it. A comparison whose runtimes were compiled under different
isolation or language-mode settings would be measuring the settings rather than
the runtimes. It is copied rather than shared because SwiftPM manifests cannot
import one another, so `StorefrontBuildShapeTests` in the `Verification`
package reads all four runtime manifests as text and fails when they drift.

## Running the tests

```sh
mise run test:storefront-runtimes
```

Never a bare filtered `swift test`: SwiftPM exits 0 when a filter selects
nothing. The wrapper enumerates the built tests first, requires every filter
alternative to match something, owns its own xUnit report, and refuses an
authoritative executed count of zero.

`mise run test:storefront-all` runs this suite together with the workload,
Cog, state-graph, and agreement suites.

## `StorefrontObservationRaw` — the floor

`RawObservationStorefrontRuntime` is the hardware floor of the comparison.
Seventeen `@Observable` stored properties hold the writable facts, ten more hold
the last accepted asynchronous response, and every derived value the Cog port
declares is an ordinary Swift function that runs end to end whenever it is
called. There is no cache, no memo, no dirty bit, no version stamp, and no
dependency edge anywhere in the derivation layer. A browse render runs the whole
search funnel **twice** — once for the visible window, once for the prefetch
margin — and runs the pricing ladder from its base price for every demanded row,
twice over for each row whose price and badges are both wanted.

That is the point rather than a defect. This port exists so the cost of Cog's
machinery can be read against what the same workload costs with Observation and
nothing else. It is expected to be slow on the pricing ladder and on search over
the full catalog, and nothing may be added to make those numbers look better —
that is what the sibling `observation-memo` port is for. The two are separate
targets so that reaching for the memo port's cache from here is a compile error
rather than a review question.

### Declared semantics, and why each value is what it is

| Field                                 | Raw   | Cog  | Why                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------- | ----- | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `browseRunsPerContentChangingTurn`    | 1     | 1    | One verb is one transaction and one render, so a multi-source verb still settles once and never renders an intermediate screen.                                                                                                                                                                                                              |
| `browseRunsPerEqualWrite`             | **1** | 0    | Writing the sort mode that is already selected renders anyway. The port cannot tell that nothing changed; knowing that is exactly what an invalidation graph is for. Declaring `0` here is explicitly prohibited.                                                                                                                            |
| `browseRunsPerUndemandedInvalidation` | **1** | 0    | An inventory burst that touches only offscreen products still renders once, for the same reason.                                                                                                                                                                                                                                             |
| `accountRunsThroughSignIn`            | 2     | 2    | Every held observer runs in every render, so registration accounts for the first account run and the accepted response for the second.                                                                                                                                                                                                       |
| `declaredUndemandedRequestStarts`     | 0     | 0    | **A tie for a structural reason, not a state-management one.** The render walks the visible window widened by the prefetch margin, so a product outside it is never asked about and its invalidated inventory generation is simply never consulted. The results table must carry this note; reporting the tie without it would be dishonest. |
| `releasesUnobservedValues`            | false | true | There is nothing to release: no derived value survives the call that computed it, and an accepted response is kept for the session. The teardown phase records an explicit skip for its release proof rather than passing it for the wrong reason.                                                                                           |
| `refusesStaleResultsByGeneration`     | true  | true | A completed response carries the generation captured synchronously at selection time and is published only if that generation is still current. Nothing here relies on task cancellation.                                                                                                                                                    |
| `hasPerGenerationRefreshHandles`      | true  | true | `refreshRecommendations()` hands back a handle the next demand resolves as superseded at the moment of replacement.                                                                                                                                                                                                                          |

Every one of these is measured rather than asserted: the trace holds the port to
each number, and `StorefrontObservationRawTests` fixes them so a change to the
declaration is a change to a test.

### Disclosed choices

Judgement calls are written down here rather than buried in the source.

1. **Rendering is port-owned, not driven by Observation's change callback.**
   `withObservationTracking`'s `onChange` fires _before_ the mutation that
   triggered it has completed, and re-registering from inside it is a scheduling
   decision rather than a settlement — so it cannot be a settlement barrier, and
   the trace reads the sink on the line after a verb returns. Each verb therefore
   applies its writes and renders exactly once, at the close of that one
   transaction. The tracking scope is kept anyway, with an empty callback, so
   that the registrar's registration and notification costs both stay inside the
   sample and this stays a measurement of raw Observation rather than of a
   hand-rolled invalidation graph wearing its name.

2. **A request-identity cache in the asynchronous layer, and only there.**
   Without it the port would spin — render, request, publish, render, request —
   because nothing else could tell it that this is the same question it already
   asked, and nobody re-fires a network request on every frame. It caches no
   derived value. Two supporting counters go with it: an accepted-catalog epoch
   and a signed-in-shopper epoch, advanced only when the accepted value actually
   changes, which is what a hand-written app's `didAcceptCatalog` amounts to.
   They exist because a request identity such as `.searchIndex` or `.offer(id:)`
   does not mention the input that invalidates it.

3. **Demand is collected during the observer pass, not by a pass before it.**
   Each asynchronous read records the identity it wants and the render
   reconciles them immediately afterwards, inside the same synchronous
   settlement. Computing the demand set in a pass of its own would run the whole
   funnel a third time per render and inflate the floor with work no
   implementation performs.

4. **A function may keep its own locals; nothing survives the call.** The funnel
   builds the product index once at the top of a pass and reads it within that
   pass. That is an ordinary local variable rather than a cache — the next call
   builds it again. The alternative, rebuilding a catalog-sized dictionary inside
   a filter that runs once per candidate, is quadratic in the catalog and would
   measure a strawman rather than a floor. The per-row keyed functions take the
   literal reading and rebuild what they need on every call, so a row whose price
   and badges are both wanted builds the index twice.

5. **The pricing ladder demands live inventory and a personalized offer only
   when the profile's policy prefix contains the stage that reads them.** Cog's
   stage graph reads a value only from the policy that needs it, so a port that
   demanded an offer for a cart line on the four-policy `smoke` ladder would
   start a request Cog is correct never to make — and would be running a
   different session, not a slower one.

Nothing here precomputes anything the Cog port computes at runtime, caches
across trace phases, knows the script in advance, or reads from another port.

## `StorefrontObservationMemo` — honest hand-written caching

`MemoObservationStorefrontRuntime` is the realistic competitor: what a competent
team actually ships when it has `@Observable`, cares about performance, and has
no reactive library. Sixteen `@Observable` stored properties hold the writable
facts, ten asynchronous cells hold the last accepted response, **seven** caches
hold the expensive derived values, and one file — `MemoObservationInvalidation.swift`
— says by hand which caches each write clears and which screens owe a re-render
because of it.

The test for whether this port is still honest is: _would a senior iOS engineer,
given this workload, a deadline, and no reactive library, write this?_ So it has
no reader that records what it read, no dependency graph, no automatic transitive
invalidation, no version stamps propagated between values, and no settlement
algorithm. Build any of those and you have built Cog, and the comparison stops
meaning anything.

### The seven caches, and where their boundaries were drawn

| Cache              | Covers                                                                                    | Cleared by                                                                                                         |
| ------------------ | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `catalogIndex`     | catalog products, categories, product index, category-name map                            | an accepted catalog                                                                                                |
| `searchPipeline`   | normalized query, tokens, candidates, per-candidate score, eligibility, ranking, sections | a query write that changes the normalization, a category / stock / sort write, an accepted catalog or search index |
| `window`           | flattened section order, visible identifiers, prefetch margin, demanded set               | anything that clears `searchPipeline`, and a row-window write                                                      |
| `pricing`          | one product's **whole** sixteen-policy ladder, as a single cell                           | that product's pricing inputs; wholesale for the shopper, coupon, address, and shipping method                     |
| `rows`             | availability, badges, and the rendered row value per product                              | alongside `pricing`, plus the favorite flag                                                                        |
| `cart`             | line identities, lines, subtotal, promotion plan, discounted subtotal                     | any cart, coupon, or shipping write; an accepted quote; a pricing change for a product in the cart                 |
| asynchronous cells | the last accepted response per asynchronous identity                                      | a request-identity change, or the lifetime sweep                                                                   |

Seven, not fifty-three. A cache boundary here is drawn where a person would
think "that is one screen's worth of work", not where a dependency edge happens
to be.

### The central judgement call: the pricing ladder is one cell per product

This is the single most important honesty decision in the port, and it is a
deliberate concession.

Cog gets **stage** granularity for free: because each of the sixteen policies
declares what it reads, changing the coupon dirties the coupon stage and
everything below it and nothing above it. This port gets none of that. It
memoizes the ladder as one cell per product and recomputes the whole thing —
from the base price up — whenever any of that product's pricing inputs move.

Reproducing Cog's granularity would mean maintaining seventeen per-policy
invalidation lists per product, by hand, in the one place this workload is
deliberately deepest. That is not a cache; it is a dependency graph with the
serial numbers filed off, and it is also not what anyone writes. So the port
declines, and the results table says so in a sentence. Expect this to be where
its wall-clock number is worst relative to Cog: the checkout phase moves the
coupon and the shipping method, and each of those rebuilds every demanded row's
ladder end to end.

The `stress` profile's three price books are handled inside the same single
call, which takes the best qualifying book in one pass.

### What the caching cost to write

**89 lines of executable Swift across 19 methods**, all of them in
`MemoObservationInvalidation.swift`, plus the hand-written demand list in
`refreshDemand()`. That is the honest denominator of every number this port
produces: it is the maintenance surface a team takes on, and it is the figure to
read beside the timings rather than instead of them.

The interesting risk in code like this is not that it is slow. It is that it goes
quietly wrong: a new pricing policy that reads the shipping address, added six
months later by somebody who never met `didWriteShippingAddress()`, shows a stale
price until something unrelated happens to clear the cache. Nothing in the port
can catch that, which is why its correctness suite compares the rendered state
with the shared shadow at **every phase boundary** rather than only at the end of
the session.

### Declared semantics, and why each value is what it is

| Field                                 | Memo | Cog  | Why                                                                                                                                                                                          |
| ------------------------------------- | ---- | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `browseRunsPerContentChangingTurn`    | 1    | 1    | A verb is one `mutate`, and a `mutate` suppresses rendering, applies every write, and renders once at its close. A multi-source verb therefore never renders an intermediate screen.         |
| `browseRunsPerEqualWrite`             | 0    | 0    | Every setter is equality-gated before it mutates and before it invalidates. That is ordinary defensive code, not a comparison of rendered output: the port never renders and then diffs.     |
| `browseRunsPerUndemandedInvalidation` | 0    | 0    | `didChangeProduct(_:pricingAffected:)` consults the demanded set the window cache maintains, so an offscreen product's cached row is dropped and nothing is marked dirty.                    |
| `accountRunsThroughSignIn`            | 2    | 2    | The account observer runs once at registration against the resting signed-out value, and once when the response is accepted.                                                                 |
| `declaredUndemandedRequestStarts`     | 0    | 0    | Demand is a hand-written list of what the held screens need, walked at every settlement. An offscreen row is not on the list, so an invalidated generation for it asks nothing.              |
| `releasesUnobservedValues`            | true | true | A time-to-live sweep over per-product entries, on the port's own injected clock. It consults the same demanded set, so a row an observer is genuinely holding survives its grace.            |
| `refusesStaleResultsByGeneration`     | true | true | Every task carries the attempt it was launched with; the epilogue publishes only if that attempt is still current. Nothing relies on cancellation — superseded tasks are not even cancelled. |
| `hasPerGenerationRefreshHandles`      | true | true | `refreshRecommendations()` hands back a handle the next demand resolves as superseded at the moment of replacement, not when its task finishes.                                              |

Every value matches Cog's, and that is this port's central **result**: careful
hand-written caching can reproduce a fine-grained graph's observable behavior.
What the comparison then reports is what reproducing it cost — in wall clock, in
allocation, and in those 89 lines. The trace holds the port to each number and
`StorefrontObservationMemoTests` fixes them, so a change to the declaration is a
change to a test. This port skips **no** checkpoint; the suite asserts that too,
because a skip records as holding and an "every checkpoint holds" loop could
never notice one appearing.

### Disclosed choices

1. **Rendering is port-owned, not driven by Observation's change callback.** The
   same deviation, for the same reason, as the raw port records above: the change
   callback fires before the mutation completes and re-registering is a
   scheduling decision rather than a settlement, while the trace reads the sink
   on the line after a verb returns. The tracking scope is kept anyway, with an
   empty callback, so the registrar's registration cost stays inside the sample —
   what the deviation removes is the scheduling, not the cost.

2. **A request-identity cache in the asynchronous layer, and only there.** The
   comparison's one carve-out for both `@Observable` ports: without it the port
   would spin, and nobody re-fires a network request on every frame. It caches no
   derived value. Three requests are keyed on an identity that does not mention
   every input they are computed from — `.searchIndex`, `.suggestions(query:)`,
   and `.recommendations(accountID:)` — so the hand-written invalidation tells
   those cells explicitly that their input moved, which is what a real
   `didAcceptCatalog` amounts to.

3. **An inventory-generation write invalidates nothing.** A generation is the key
   the next request is asked under, not a value a row renders, so a burst
   settles, marks no cache stale, runs no observer, and lets the demand pass
   notice that the demanded rows' identities moved. Every row keeps showing the
   last accepted reading until the new one lands — which is also exactly what the
   Cog port does, because there the generation is read by the asynchronous
   selector rather than by anything downstream of the value.

4. **The order total and the checkout readiness are not cached.** They are three
   additions and a handful of comparisons over the cart cache plus two accepted
   quotes. Caching them would mean an accepted quote had to invalidate the cart —
   and re-run the promotion optimizer — so recomputing them per cart render is
   both cheaper and one less line of invalidation to maintain.

5. **Superseded tasks are not cancelled.** Correctness comes from the generation
   check, and the scripted request boundary leaves cancelled requests suspended
   by default anyway, so cancellation could not be the mechanism. Under the
   script this is also behaviorally identical to the Cog port, whose cancelled
   tasks likewise stay suspended until the driver releases them; what it buys is
   an exact one-release-one-decision accounting for the completion barrier.

6. **The catalog cache holds a category-name map.** The Cog port's row builder
   performs a linear search over the categories instead. The map is part of the
   catalog cache this port declares, and building it is work this port does at
   catalog-acceptance time that the Cog port does not.

7. **The pricing ladder demands live inventory and a personalized offer only
   when the profile's policy prefix contains the stage that reads them.** Same
   rule as the raw port, for the same reason: demanding an offer for a cart line
   on the four-policy `smoke` ladder would start a request Cog is correct never
   to make.

Nothing here precomputes anything the Cog port computes at runtime, caches across
trace phases, knows the script in advance, or reads from another port.

## Current state

Both ports are implemented and green against the shared shadow. Every number
either one publishes rests on `mise run test:storefront-runtimes` passing in the
same session: the eleven-phase trace end to end, agreement with the shadow at
every phase boundary, and the declared semantics each port is held to.

Both ports' measured cuts are `perf-16-storefront-observation-raw-<cut>` and
`perf-16-storefront-observation-memo-<cut>`. The recorded numbers, the declared
semantics as the agreement gate printed them, the 89-line invalidation
denominator read beside the memo port's timings, and what the comparison does
not establish are in
[`docs/swift/impl/perf.md`](../../../../../docs/swift/impl/perf.md#cross-runtime-results).
