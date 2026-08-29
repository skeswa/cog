# Cog: design history

_Authored August 21, 2026._

This page keeps only the history needed to explain today's design. It does not
define current behavior. Use the [shared state model](./design.md),
[Swift docs](./swift/README.md), and [Kotlin docs](./kotlin/README.md) for that.

## The original problem

Cog grew from Ditto Subject/BLoC, a state system for a large Flutter web app.
It used small writable facts and pure computed values. That made ownership
clear and let Flutter update only the widgets that read a changed fact.

Three problems led to Cog:

1. **Too much setup.** A small feature could need several framework objects and
   providers. Teams often made a second local state system instead, which gave
   one fact more than one writable copy.
2. **Mixed states.** Each stream published on its own. A widget could see a new
   input with an old computed value while a change moved through the graph.
3. **Wrong ownership.** Root objects made local facts look global. Nested
   feature runtimes looked better, but split the app into separate state islands.

The new goal was one app-wide graph with small values, controlled writes,
complete updates, keyed state, precise UI refreshes, and clear async behavior.

## Names changed; roles stayed

Early drafts used several names for the same jobs:

| Current role         | Earlier names                    |
| -------------------- | -------------------------------- |
| State descriptor     | Subject, `Cog.simple`, `Cog.man` |
| Keyed box            | context Cog, scoped Cog          |
| Named operation      | action, maneuver, lever, `Op`    |
| Effect               | mechanism, `Cogtext.run`         |
| Source-code grouping | BLoC, `Machine`                  |
| App runtime          | Conveyor, Cogtext                |
| Project              | Conveyor, Machina, ARP           |

Today, a descriptor names one fact, an operation asks for a change, and an
effect acts outside the graph. Files and packages group feature code. They do
not create feature runtimes.

## Short timeline

### 2022: small state facts

The first notes described app state as a graph with one source for each fact.
Recoil and Flutter's `InheritedModel` showed the value of small declarations
and narrow UI updates. The missing part was a graph-owned way to publish a full
change at once.

### 2023: one runtime, dynamic links, and keys

The first Cog drafts split writable state from computed and streaming state.
Reads recorded their dependencies. Effects watched state. Runtime extensions
formed the app's write API.

A short-lived `Machine` class grouped each feature's state and lifecycle. It
was soon removed in favor of normal files and one app runtime. This became a
core rule: source-code layout must not split runtime state.

Early per-item state used an unnamed scope. Callers then had to carry that scope
through unrelated code, and a source could not say which scope it used. Typed
keys replaced it. One `CogBox` could now define a state shape for many items,
while each item kept separate tracking.

Later 2023 work added named sync and async operations, reactions, controlled
reads, cache ideas, lints, and migration bridges. It also separated two ideas
that remain separate today: how old a value is and how long the runtime keeps it.

### 2026: native Swift and Kotlin designs

The last Dart draft reduced the front door to sources, automatic state, keyed
boxes, controlled reads, and reactions. The team then tested the same model on
native platforms instead of shipping another Dart API.

Swift came first and uses Observation only at the SwiftUI boundary. The Kotlin
design originally considered using Compose snapshots as its graph engine, then
converged on the same Cog-owned runtime model with Compose state only at the UI
boundary. The libraries keep minor language-native API differences while
sharing state semantics and turn behavior.

## What remains

The current designs kept:

- small source and automatic declarations;
- dependencies found from real reads;
- keyed state families;
- named operations and complete turns;
- effects outside automatic state;
- clear async overlap and stale-result rules;
- narrow native UI updates;
- stable identity and useful debug history; and
- isolated runtimes for tests and previews.

They rejected or limited:

- nested production runtimes for features or screens;
- runtime `Machine` objects for source-code grouping;
- line numbers or stack traces as lasting state identity;
- global getters that hide tracked reads;
- separate, loosely linked values for async data and failure; and
- old Flutter hooks, Dart generators, and Subject bridges as shared rules.
