# Cog: design history

_Authored August 21, 2026._

Cog began as an attempt to simplify a Dart and Flutter state system and became
a pair of platform-native designs for SwiftUI and Jetpack Compose. This
document preserves that lineage without making an obsolete Dart API the entry
point to either current library.

The current cross-platform contract is [the shared state model](./design.md).
The [Swift](./swift/README.md) and [Kotlin](./kotlin/README.md) maps describe
the live platform decisions. History explains why those decisions were asked
for; it does not override them.

## The starting problem

The predecessor was Ditto Subject/BLoC, built for a large Flutter web app from
ideas in NgRx and Flutter's BLoC pattern. Small subjects represented writable
facts and pure derivations. That made ownership and cause visible, and it let
Flutter rebuild only consumers of a changed fact.

Three failures motivated a replacement:

1. **The useful path required too much ceremony.** A feature might need a BLoC,
   an entity-level BLoClet, glue, and a provider before it could declare one
   fact. Developers reasonably built local state machines instead, splitting
   authority across the app.
2. **Stream propagation exposed intermediate values.** A chain updated one
   subject at a time, so a widget could combine a new upstream value with an
   old downstream one. The notes called this the “telephone problem.”
3. **The architecture confused scope with ownership.** Root-owned BLoCs made
   local facts global, while the “business logic” name discouraged using the
   graph for UI state. Runtime nesting looked like a solution, but it created
   state islands rather than a coherent app model.

The durable goal was therefore not simply “signals for Flutter.” It was normal
application code over one explainable state graph, with controlled writes,
coherent turns, keyed state, precise UI invalidation, and explicit async
behavior.

## Names and metaphors

The design changed names several times while its jobs stabilized:

| Job                  | Earlier names                    | Current role                                 |
| -------------------- | -------------------------------- | -------------------------------------------- |
| One state fact       | Subject, `Cog.simple`, `Cog.man` | a Cog descriptor or value reference          |
| Keyed family         | context Cog, scoped Cog          | `CogBox`                                     |
| Named write          | action, maneuver, lever, `Op`    | a domain operation around a turn             |
| Side effect          | mechanism, `Cogtext.run`         | Swift `Mechanism` or Kotlin effect/reaction  |
| Feature organization | BLoC, `Machine`                  | an ordinary source file, package, or feature |
| Runtime              | Conveyor, Cogtext                | Swift `Cogs` or Kotlin `CogStore`            |
| Project              | Conveyor, Machina, ARP           | Cog                                          |

The mechanical metaphor was useful: a cog names one fact; an op
asks for a state change; a mechanism acts outside the graph; and a conveyor
orders the work. The current APIs keep the distinctions without requiring a
runtime `Machine` object or sharing the same vocabulary on both platforms.

## How the design evolved

### 2022: a graph of small facts

The original BLoC notes described application state as a directed graph with
one source for each fact. Recoil and Flutter's `InheritedModel` reinforced two
ideas: declarations can be small, and a UI should depend on one aspect rather
than rebuild for a feature-sized object.

The missing piece was a coherent graph-owned update schedule. Independent
subjects had the right granularity but the wrong publication model.

### March 2023: Cog, Conveyor, and dynamic links

The first Cog sketches split writable state from computed or streaming state.
A controller read dependencies, mechanisms watched state, and extension
methods formed the app's write API.

A short-lived `Machine` class grouped state, methods, and an `operate`
lifecycle. Within days the declarations moved to ordinary top-level Dart
libraries and one Conveyor runtime. That change established a lasting rule:
source organization should not require one runtime object per feature.

The same drafts introduced per-entity state, dependencies that could change on
each run, async overlap policies, a fake runtime, Flutter hooks, and generated
registration. They first modeled entity identity as an implicit context or
scope. Feedback showed that a source could not state which scopes it belonged
to and callers had to carry scope through unrelated layers.

Typed keys replaced scope. A key could flow within a keyed derivation, while a
boundary to another entity required an explicit key. This became the `CogBox`
idea: one declaration, many independently tracked values.

### June and July 2023: smaller declarations and named operations

Under the Machina name, the surface became manual, automatic, and procedural
cogs plus first-class sync and async operations. Operations could expose
in-flight calls and the latest failure. Reactions and local derivations became
smaller, and reads stayed behind a capability so dependencies could not be
hidden in a global getter.

The design also explored query-style time-to-live, one-shot UI reads, runtime
identity from stack traces, and custom lints. The `Machine` class was dropped
for good. A lint or language access control could restrict writes to the file
that owns a source while ordinary extension methods supplied domain verbs.

This period also clarified a distinction the current design keeps: freshness
is not lifetime. An async result may be stale and retained, while an unused
value may be fresh and releasable.

### September and November 2023: ARP, Cogtext, and migration

The ARP experiment — Algebraic effect, Reactive state, Primitive — tested names
and `StateNotifier` as storage without changing the graph model.

The later Cogtext sketch returned to Cog vocabulary, used callbacks for fresh
initial values, made runtime extensions the home for named application
operations, and proposed bridges to the old Subject system. Those bridges made
incremental migration possible but did not change the ownership rule: only one
side should remain writable.

### January 2026: the compact signals surface

The final Dart sketch described Cog plainly as an ergonomic signals design for
simplicity, correctness, and performance. Its front door was small:

- a manual declaration for one source;
- an automatic declaration whose reads capture dependencies;
- a `CogBox` for a keyed family;
- one controller read operation; and
- a runtime reaction at the graph's edge.

The sketch asked whether the same model fit Swift. That question led to the
current repository: Swift first, using Observation only at the UI boundary;
then a separate Kotlin design that reuses the Compose snapshot runtime.

## What carried forward

The current platform designs retain these ideas:

- small source and automatic declarations;
- dynamic dependencies captured from reads;
- keyed families as a first-class shape;
- named domain operations and atomic turns;
- settled publication instead of stream-by-stream propagation;
- side effects outside automatic computation;
- explicit async overlap and stale-result rules;
- fine-grained native UI tracking;
- stable runtime identity, readable labels, and explainable history; and
- isolated runtimes with deterministic setup for tests and previews.

Several older directions were deliberately narrowed or rejected:

- Production does not create nested Cog runtimes for features or screens. One
  app has one authoritative graph; truly view-local state stays native.
- A feature is not a runtime `Machine` object. Files, types, and packages
  organize declarations and operations.
- Stack traces and source lines may provide debug labels, not durable state
  identity.
- A free global getter does not hide tracked reads. Reads go through a runtime
  or scoped capability.
- Async uncertainty does not rely on an ad hoc pair of `.live` and
  `.latestFailure` values. Each platform defines one coherent status model.
- Flutter hooks, Dart generators, and Subject bridges are historical vehicles,
  not cross-platform requirements.
