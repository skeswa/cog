# Reading state

_August 26, 2026_

A correct normal read uses the latest completed turn and settles every
dependency needed for that value — the runtime guarantees that. What the
handbook adds is a discipline for how reads _look_, so a reader of the code
can see what a view or computation depends on without executing it in their
head.

## Unwrap every read into a domain local

In application code and user-facing examples, bind each value-producing
`c[...]`, `cogs[...]`, or status/peek read to a local before using it. Name
that local by removing the declaration's final `Cog` or `Cogs`:

```swift
let selectedTab = c[selectedTabCog]
let tabPath = c[tabPathCogs[selectedTab]]
let savedTrailIDs = cogs[savedTrailIDsCog]
```

For a status read, keep the same clean name — do not add a `Status` suffix
even though the local's type is `CogStatus`:

```swift
let forecast = cogs.status[weatherForecastCogs[zip]]
if forecast.isLoading { … }
```

Creating the local observes no field by itself, so SwiftUI still tracks only
the fields the body actually uses. The rule applies in views, selectors,
reactions, and operations. Three call shapes need not invent a local: writer
lvalues (`c[_selectedTabCog] = tab`), commands that accept a value reference
(`refresh(weatherForecastCogs[zip])`), and low-level tests isolating an exact
read expression.

The payoff is uniform vocabulary: `selectedTabCog` is always the reference,
`selectedTab` is always the value, and a reviewer never wonders which of the
two a line is handling.

## Read flatly; never repackage reads into a projection type

A view that needs several values reads each one on its own line and binds it
to a domain local, however many there are. Do not gather them into a struct —
not one built by an initializer taking `Cogs`, and not one built by a `Cogs`
extension.

A projection type adds a layer that must be read to know what the view
depends on, invites being stored or passed onward, and buys nothing: reads in
one `body` already come from one settled turn, and each read already
registers on its own, so unrelated turns invalidate nothing. If a value is
genuinely automatic rather than merely read together, declare an automatic
cog and read that flatly too ([Declaring state](./declaring-state.md)).

## Tracked reads, one-time reads

Tracked reads use subscripts — `c[…]` inside a computation or reaction,
`cogs[…]` in a view body — and register a dependency. One-time reads use
`peek`: the value still settles, but no dependency and no Observation access
is recorded.

Use `peek` where a dependency would be wrong: a mechanism's `operate`-time
read, a `whenever` body consulting state without re-triggering the scope, and
test assertions (`cogs.peek(savedTrailIDsCog)`).

## Async reads are total; uncertainty is opt-in

A normal read of an async declaration always returns a value: the last
accepted success, or the declaration's default before one exists. Code that
does not care about request lifecycle reads the plain value and stays stable
across reloads:

```swift
let weatherForecast = cogs[weatherForecastCogs[zip]]   // last accepted, or nil
```

Code that renders request chrome opts into the `status` lens and reads only
the fields it needs — `kind`, `value`, `hasSucceeded`, `error`, `isLoading` —
because SwiftUI tracks per field:

```swift
let forecast = cogs.status[weatherForecastCogs[zip]]
if forecast.isLoading { ProgressView() }
```

Keeping the two spellings separate keeps derived state calm: an automatic
value computed from the plain read changes only when an accepted value does,
not on every pending flicker.
