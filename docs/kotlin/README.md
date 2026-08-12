# Cog for Kotlin and Jetpack Compose

_Authored August 6, 2026._

Cog is a fine-grained state graph for Android UI. It uses the Compose snapshot
runtime as its engine. Cog adds names, write rules, async work, lifetimes, and
debug tools.

The goal is small code that stays correct under change.

## Design principles

1. Cog should feel simple.
2. Every state read should be correct.
3. Cog should minimize runtime overhead without weakening the other rules.
4. Cog state should be singular. One running app has one authoritative graph,
   each mutable fact represented in Cog has one writable source in it, and
   screens or features do not create state islands or mirror sources.

## Start here

1. [§1–§5 and §7–§11: core design](exploration.md)
2. [Full weather feature](example.md)
3. [§5.4: Flow and reactive-library mapping](flows.md)
4. [§6: effects and background work](effects.md)
5. [Performance model and spike plan](perf.md)

The section numbers match the Swift set where that helps comparison. The
Kotlin choices stand on their own.

## The short version

One process-wide `CogStore` owns the production graph. A descriptor
such as `Cog<User>` names one value in that graph. A keyed descriptor
such as `CogBox<User, UserId>` names a set of values.

Compose already has the right low-level parts:

- `MutableState` stores source values.
- `derivedStateOf` caches derived values and tracks changing dependencies.
- snapshots make a group of writes visible at once.
- a `State` read invalidates only the Compose scopes that used it.

Cog builds policy around those parts:

- the app creates one store and shares it across every screen;
- descriptors have stable identity and readable debug labels;
- writable descriptors stay private;
- all writes happen in a named `commit`;
- UI, reactions, and Flow collectors keep only the graph they need alive;
- async state is explicit in `CogPhase`;
- debug builds can explain why a value changed.

```mermaid
flowchart LR
    UI["Composable"] -->|"read"| State["Cog state<br/>Compose State"]
    Event["Event handler"] -->|"commit"| Store["CogStore"]
    Store -->|"snapshot write"| State
    State --> Derived["derivedStateOf"]
    Derived --> UI
    Store -.-> Policy["names · lifetime · async · debug"]
```

The common path stays small:

```kotlin
private val countSource = ManualCog(0)
val count = countSource.readOnly
val doubled = Cog { get(count) * 2 }

fun CogStore.increment() = commit("increment") {
    countSource.value += 1
}

@Composable
fun Counter() {
    val store = cogs
    val value = store[doubled]

    Button(onClick = store::increment) {
        Text(value.toString())
    }
}
```

The application or dependency-injection root creates the store once.
`CogProvider` exposes that same store at the root of Compose. A screen
or ViewModel never creates or closes the production store.
Production construction is guarded, so a second app graph fails fast.

Tests and previews may create isolated stores. That keeps test state separate
without changing the production singleton rule.

## Where things stand

The first design is ready for a prototype. The prototype must prove:

- staged and atomic writes;
- escaped-writer failure in every build;
- dynamic derived dependencies;
- exact Compose invalidation;
- ordered reactions;
- keyed state cleanup;
- async cancellation and stale-result guards;
- acceptable cost beside raw Compose state.

No Kotlin library exists yet. Performance representation choices remain open
until the spike and benchmarks in [§9](perf.md#9-spike-and-benchmark-plan).

## Reading rules

“Decision” means the first prototype should follow it. “Candidate” means the
spike must test it. Appendix material explains trade-offs but should not be
needed for normal use.

The dated [old Dart and Flutter dump](../dump-2026-08-06.md) is background
only. It is not the Android design.
