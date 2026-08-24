# swift-state-graph 0.28.0 — confirmed API reference

Written 2026-08-24 for the four-runtime Storefront comparison.

This is a reference document, not a design document. Everything below was read
out of the pinned checkout or measured by running it. Nothing here is inferred
from a README, and every claim carries either a `file:line` or the probe output
that produced it.

## The pin

| Fact                   | Value                                                 |
| ---------------------- | ----------------------------------------------------- |
| Checkout               | `swift/Benchmarks/.build/checkouts/swift-state-graph` |
| `git describe --tags`  | `0.28.0`                                              |
| HEAD                   | `e602fcdb19342a38c135543e7228b3fd60753dc7`            |
| Resolved by            | `swift/Benchmarks/Package.resolved`, lines 59–65      |
| Manifest tools version | `6.3` (`Package.swift:1`)                             |
| Platforms              | macOS 14, iOS 17, tvOS 17, watchOS 10                 |
| Swift language mode    | `.v6`                                                 |

The package's own dependencies are swift-typed-identifier (used by the
`StateGraphNormalization` target) and swift-syntax (the macro plugins).
swift-macro-testing is test-only and SwiftPM prunes it — `Package.resolved`
lists swift-typed-identifier at 2.0.4 and no macro-testing entry. A consumer
that depends only on the `StateGraph` product still resolves all three of
swift-state-graph, swift-syntax, and swift-typed-identifier, which is the whole
reason the port lives in a package of its own.

Re-confirm the pin before touching the port:

```
git -C swift/Benchmarks/.build/checkouts/swift-state-graph describe --tags
```

## The probe

The measurements quoted throughout live in `Probe/`, a SwiftPM package named
`sgprobe` that depends on swift-state-graph `exact: "0.28.0"`. Run it with:

```
swift run --package-path swift/Benchmarks/Macro/Storefront/StateGraph/Probe sgprobe
```

Its output is identical in debug and in release configuration.

## 1. `Stored` — the mutable source

`Sources/StateGraph/Primitives/Stored.swift:15`

```swift
public final class Stored<Value: SendableMetatype>: Node, Observable, CustomDebugStringConvertible
```

Note the `SendableMetatype` constraint on `Value`. It is not `Sendable`; the
library's own comment (`StateGraph.swift:13-15`) explains that the constraint
exists so the node's `@Sendable` closures may use generic conformances.

### 1.1 Initializers — four of them, and the choice is silent

The designated initializer, `Stored.swift:542`:

```swift
public init(
  _ file: StaticString = #fileID,
  _ line: UInt = #line,
  _ column: UInt = #column,
  name: StaticString? = nil,
  wrappedValue: consuming Value,
  shouldNotify: @Sendable @escaping (Value, Value) -> Bool
)
```

and **four** convenience initializers with the same argument labels, which
differ only in their generic constraints:

| `Stored.swift` | Constraint                     | `shouldNotify`                                        |
| -------------- | ------------------------------ | ----------------------------------------------------- |
| 645            | none                           | `{ _, _ in true }` — **notifies on every assignment** |
| 667            | `Value: Equatable`             | `{ $0 != $1 }`                                        |
| 687            | `Value: AnyObject`             | `{ $0 !== $1 }`                                       |
| 708            | `Value: Equatable & AnyObject` | `{ $0 != $1 }`                                        |

Overload resolution picks the most constrained applicable one, so
`Stored<Int>(wrappedValue: 1)` is equality-gated. **Confirmed by measurement**
(probe `a1`): an equal write to a `Stored<Int>` recomputes nothing downstream,
a different write recomputes once.

```
a1 downstream runs after first read: 1
a1 downstream runs after EQUAL upstream write: 1
a1 downstream runs after DIFFERENT upstream write: 2
```

The trap is line 645. A `Value` that is not `Equatable` — an `AsyncCell` struct
holding a `[ProductID]`, a generation, and an in-flight identity, for instance —
lands there silently and notifies on **every** assignment. Every `Stored`
`Value` the port declares must be `Equatable`, and that is worth an explicit
`grep`.

### 1.2 `name:` is `StaticString?`

`Stored.swift:546`, and `Computed`'s is the same. Node names must be literals;
`"storefront.price.\(id)"` will not compile. Use one literal per node _kind_ and
keep identity in the port's own dictionaries.

### 1.3 Reading and writing

`Stored.swift:105-134`:

```swift
public var wrappedValue: Value {
  get {
    if ThreadLocal.graphTransaction.value != nil {
      return transactionValue()
    }
    return GraphTransactionCoordinator.shared.withReadAccess {
      committedValue()
    }
  }
  set {
    assertGraphMutationAllowed("Stored.wrappedValue mutation")
    if let transaction = ThreadLocal.graphTransaction.value {
      stage(newValue, in: transaction)
      return
    }
    …withImmediateWrite…
  }
}
```

Inside a transaction the getter returns the node's own staged value
(`transactionValue()`, `Stored.swift:140-173`, specifically the
`if transactionBuffer != nil { return transactionBuffer!.value }` at 162-164).
Read-your-own-staged-writes is native. **Confirmed by measurement** (probe `b1`,
`b3`): a transaction that writes `window = window + 10` settles at the staged
value, and a synchronous `onDidSet` handler run during the transaction observes
`a:1` while `a`'s new value is still staged.

### 1.4 Other members the port will touch

| Member                                                                  | `Stored.swift` | Note                                                                                                                                                                      |
| ----------------------------------------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `public func onDidSet(_ handler: @escaping (Value, Value) -> Void)`     | 633            | Runs synchronously for every assignment, inside and outside a transaction (`GraphTransaction.swift:15-19`). Only one handler per node — a second call replaces the first. |
| `public borrowing func unsafeModify<Result, E>(_:) throws(E) -> Result` | 604            | **Prohibited by the port's fairness rules.** Bypasses invalidation, staging, rollback, and `onDidSet`.                                                                    |
| `public var outgoingEdges: ContiguousArray<Edge>`                       | 534            | Public and readable; the probe uses it to prove edge cleanup on eviction.                                                                                                 |
| `public var incomingEdges`                                              | 524            | Getter **and** setter are `fatalError()`. A `Stored` has no incoming edges. Do not write code generic over `any TypeErasedNode` that reads this.                          |
| `public var potentiallyDirty`                                           | 94             | Getter returns `false`; setter is `fatalError()`. Same warning.                                                                                                           |

## 2. `Computed` — the derived node

`Sources/StateGraph/Primitives/StateGraph.swift:130`

```swift
public final class Computed<Value: SendableMetatype>: Node, Observable, CustomDebugStringConvertible
```

### 2.1 Initializers — the memoization decision

Three initializers, all with identical argument labels:

```swift
// StateGraph.swift:327 — explicit descriptor
public init(
  _ file: StaticString = #fileID, _ line: UInt = #line, _ column: UInt = #column,
  name: StaticString? = nil,
  descriptor: some ComputedDescriptor<Value>
)

// StateGraph.swift:357 — NON-memoizing: isEqual is { _, _ in false }
public init(
  _ file: StaticString = #fileID, _ line: UInt = #line, _ column: UInt = #column,
  name: StaticString? = nil,
  rule: @escaping @Sendable (inout Context) -> Value
)

// StateGraph.swift:387 — MEMOIZING: isEqual is { $0 == $1 }
public init(
  _ file: StaticString = #fileID, _ line: UInt = #line, _ column: UInt = #column,
  name: StaticString? = nil,
  rule: @escaping @Sendable (inout Context) -> Value
) where Value: Equatable
```

The two `rule:` overloads differ only in the `where` clause, and the library's
doc comment on the memoizing one at 376-386 is a copy-paste of the
non-memoizing one's — it still says "uses a comparison function that always
returns `false`". Ignore the comment; read the body. Line 398 is
`AnyComputedDescriptor(compute: rule, isEqual: { $0 == $1 })`.

**Confirmed by measurement** that the trailing-closure `rule:` form binds the
memoizing overload whenever `Value: Equatable` (probe `a2`, `a4`), and that the
probe can tell the difference (probe `a3`, which builds the non-memoizing
descriptor explicitly and sees the downstream rule run twice):

```
a2 middle runs after upstream change mapping to an EQUAL middle value: 2
a2 leaf runs after upstream change mapping to an EQUAL middle value: 1
a2 verdict: Computed MEMOIZES: the Value: Equatable overload bound
a3 leaf runs with an explicitly NON-memoizing middle: 2
a4 Computed<Row> leaf runs (1 = memoizing): 1
a4 Computed<[Int]> leaf runs (1 = memoizing): 1
a4 Computed<[Int: Int]> leaf runs (1 = memoizing): 1
a4 Computed<String> leaf runs (1 = memoizing): 1
a4 Computed<Int?> leaf runs (1 = memoizing): 1
a4 Computed<OpaqueRow> (NOT Equatable) leaf runs: 2
```

Arrays, dictionaries, strings, optionals, and plain `Equatable` structs all
memoize. A `Value` that is not `Equatable` silently binds line 357 and turns
that branch of the graph into a raw floor.

### 2.2 What the equality gate actually gates

It gates **propagation**, not the node's own recomputation. `StateGraph.swift:
482-497`:

```swift
if let previousValue = previousValue,
   withGraphMutationProhibited(.computedDescriptor, {
     descriptor.isEqual(lhs: previousValue, rhs: _cachedValue!)
   }) == false
{
  for edge in outgoingEdges { edge.isPending = true }
}
```

An invalidated `Computed` recomputes its own rule on the next read regardless.
What memoization buys is that its _dependents_ do not: probe `a2` shows the
middle node running twice and the leaf running once.

### 2.3 Reads are lazy, and reads settle

`StateGraph.swift:252-262` and `288-303`. `wrappedValue`'s getter calls
`recomputeIfNeededWithinReadAccess()` (`StateGraph.swift:437-504`), which walks
`incomingEdges`, recomputes each upstream node that needs it, and recomputes
this node only if an incoming edge is pending or the cache is empty
(`StateGraph.swift:453`, `459-464`).

There is no push. A write marks dependents `potentiallyDirty` and marks edges
pending; nothing recomputes until something reads.

### 2.4 A tracked read inside a rule; an untracked read outside one

`StateGraph.swift:442-451` and `Stored.swift:189-197`. An edge is recorded only
when `ThreadLocal.currentNode.value` is non-`nil` — that is, only when the read
happens inside another node's rule. A `TrackingRegistration` is recorded only
when `ThreadLocal.registration.value` is non-`nil` — that is, only inside a
`withGraphTracking` scope.

The port renders explicitly and registers no tracking scopes, so **every read it
makes from its own code is already untracked**. `peekEffectivePrice(of:)` and
`peekPromotionPlan()` need no special path; they create no dependency and extend
no lifetime. What keeps a node alive is the port's dictionary holding it, not
the read.

### 2.5 Rules are `@Sendable` and may outlive their creator

`rule: @escaping @Sendable (inout Context) -> Value`. The existing worked pattern
is `swift/Benchmarks/Benchmarks/CogGraph/StateGraphRuntimeComparisonGraph.swift`
lines 61-77: capture the port's node storage `[unowned storage]` and re-enter
with `MainActor.assumeIsolated`. Reuse it verbatim, comment included.

`Context` (`StateGraph.swift:132-169`) carries `environment` and
`withoutTracking(_:)`. The port needs neither.

## 3. `withGraphTransaction` — the batching API

`Sources/StateGraph/GraphTransaction.swift:76`

```swift
@discardableResult
public func withGraphTransaction<Result, Failure: Error>(
  _ file: StaticString = #fileID,
  _ line: UInt = #line,
  _ column: UInt = #column,
  _ body: () throws(Failure) -> Result
) throws(Failure) -> Result
```

Synchronous, nonescaping, thread-local. Nested calls **join** the active
transaction rather than opening a savepoint (`GraphTransaction.swift:84-87`,
and the doc comment at 27-30).

It preconditions that it is not entered from inside a committed graph read
(`GraphTransaction.swift:89-92`): a port must never mutate from inside a
`Computed` rule.

When the outermost call returns, every staged value is committed and every
dependent is flagged. The commit trampoline
(`commitTransactionBatches`, `GraphTransaction.swift:145-197`) drains
Observation-generated follow-on batches synchronously before returning.

### 3.1 What a transaction does and does not buy

**It does not coalesce recomputations.** `Computed` is pull-based, so N writes
followed by one read produce one recomputation with or without a transaction.
Measured (probe `b1`, `b2`):

```
b1 rule runs after the transaction returned, BEFORE any read: 0
b1 rule runs after one read: 1
b1 settled value (expect 1 + 2 + 1 + 10 = 14): 14
b2 rule runs after four UNBATCHED writes, before any read: 0
b2 rule runs after one read: 1
```

**It buys atomic visibility, read-your-own-staged-writes, one notification
wave, and rollback.** Those are the properties the multi-source Storefront verbs
actually need, and they are real: probe `b3` shows a synchronous `onDidSet`
observer reading a staged value mid-transaction, and the doc comment at
`GraphTransaction.swift:5-13` describes other threads continuing to read the old
committed graph until publication.

The practical consequence for the port: `applyBrowseFilters`, `openProduct`,
`addToCart`, `setCartQuantity`, and `publishInventoryBurst` each get exactly one
`withGraphTransaction`, and correctness — not run counting — is the reason.

### 3.2 Never read a derived value inside your own transaction

`StateGraph.swift:264-286`: `transactionValue()` evaluates the rule from staged
values and deliberately touches neither the committed cache nor the edge set.
Every read re-runs the whole rule. Measured (probe `b4`):

```
b4 rule runs for three reads INSIDE a transaction: 3
b4 rule runs total, after one read outside it: 4
```

Three reads inside the transaction cost three full rule evaluations, and the
first read _after_ it costs a fourth because none of them updated the cache. A
verb writes inside the transaction and renders after it.

## 4. Observation and tracking — and why the port cannot use it

| Symbol                                                                                                               | Location                                                   |
| -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `public func withGraphTracking(_ scope: () -> Void) -> AnyCancellable`                                               | `Observation/withGraphTracking.swift:70`                   |
| `public func withGraphTrackingGroup(_ handler: @escaping () -> Void, isolation: isolated (any Actor)? = #isolation)` | `Observation/withGraphTrackingGroup.swift:93`              |
| `public func withGraphTrackingMap<Projection>(…)` — four overloads                                                   | `Observation/withGraphTrackingMap.swift:55, 128, 219, 299` |
| `extension Node { public func observe() -> GraphObservation<Self.Value> }`                                           | `Observation/Node+Observe.swift:96`                        |
| `public struct GraphObservation<Element: Sendable>: AsyncSequence`                                                   | `Observation/GraphTracking.swift:30`                       |

Re-application is **deferred through a task hop**. The mechanism is
`TrackingInvalidationCallback.callAsFunction()`,
`Observation/withTracking.swift:164-172`:

```swift
func callAsFunction() {
  Task { [self] in
    if let isolation {
      await perform(isolation: isolation)
    } else {
      perform()
    }
  }
}
```

The recursion that re-arms tracking is
`_withContinuousStateGraphTracking` (`withTracking.swift:106-131`), whose
`case .next:` comment at line 119 reads "continue tracking on next event loop".

**Confirmed by measurement** (probe `d2`):

```
d2 handler runs at registration: 1
d2 handler runs SYNCHRONOUSLY after the write settled: 1
d2 handler runs after yielding to the runloop: 2
d2 verdict: tracking re-application is DEFERRED: it cannot be a settlement barrier
```

The handler runs once at registration, does **not** run when the write settles,
and runs on a later turn of the runloop. The trace reads the sink on the very
next line, so `withGraphTracking` cannot be the port's observer mechanism. The
port renders explicitly at the close of each verb. That is a scheduling
mismatch, not a defect, and it must be disclosed in the port's doc comment, in
`swift/Benchmarks/README.md`, and in `docs/swift/impl/perf.md`.

## 5. The definite settlement signal

**The read is the signal.** There is nothing else, and nothing else is needed.

`withGraphTransaction` returns only after `commitTransactionBatches` has drained
every batch (`GraphTransaction.swift:121-128`), so committed values are
published and dependents are flagged. `Computed.wrappedValue`'s getter then
settles the entire upstream funnel synchronously on the reading thread:
`StateGraph.swift:252-262` → `committedValue()` at 288-303 →
`recomputeIfNeededWithinReadAccess()` at 437-504, whose loop at 455-457 is
`for edge in incomingEdges { edge.from?.recomputeIfNeeded() }`.

Measured (probe `d`):

```
d rule runs immediately after withGraphTransaction returned: 0
d value on the next line: 42
d rule runs after that read: 1
```

Zero recomputations at the moment the transaction returns; the correct value on
the next line; exactly one recomputation to produce it.

For the port this means the render step at the close of each verb is both the
settlement barrier and the observation: reading the root `Computed`s is what
settles them, and the values it reads are what it deposits into the
`StorefrontSink`.

**Asynchronous settlement has no library signal at all.** See §6.

## 6. Async — the library supplies none

The complete public surface of the `StateGraph` module was enumerated. There is
no async node primitive comparable to Cog's `Async`. What exists is:

- `Node.observe() -> GraphObservation<Value>` (`Node+Observe.swift:96`), an
  `AsyncSequence` of values for consuming changes, not for producing them.
- `GraphUserDefault` (`UserDefaults/GraphUserDefault.swift:11`), an unrelated
  `UserDefaults` persistence bridge.

The port authors its own async layer: a `Stored<AsyncCell<Value>>` per async
identity, a `Computed<StorefrontRequestID?>` per selector, a port-owned
generation counter, and `StorefrontCompletionSignal` fired on both the publish
and the discard branch. That plumbing's cost is inside the port's numbers and
`impl/perf.md` says so. Remember §1.1: `AsyncCell` must be `Equatable` or its
`Stored` notifies on every assignment.

## 7. Keyed and dynamic node collections

The library has none. `NodeStore` (`Sources/StateGraph/NodeStore.swift:2`) is a
`public actor` holding **weak** references, populated only under `#if DEBUG`
(`Stored.swift:558-560`, `StateGraph.swift:341-343, 371-373, 401-403`), disabled
by default (`isEnabled = false`, `NodeStore.swift:7`), and existing to render
`graphViz()`. It is not a registry a port can key into.

So the keyed collection is a plain `[Key: Stored<T>]` / `[Key: Computed<T>]` the
port owns, and its cost belongs to the port. That works. Measured (probe `c`):

```
c nodes materialized before any demand: 0
c nodes materialized after demanding keys 7 and 8: 2
c rule runs so far: 2
c rule runs after re-demanding key 7 with nothing changed: 2
c evicted Computed deallocated: true
c evicted Stored deallocated: true
c upstream Stored's outgoing edges before eviction: 2
c upstream Stored's outgoing edges after eviction: 1
```

Nodes are created on first demand, a re-demand with nothing changed costs no
rule invocation, and dropping the dictionary entries deallocates both nodes.
Edge cleanup is automatic: `Edge` holds both endpoints weakly
(`StateGraph.swift:627-628`) and `Computed.deinit` (`StateGraph.swift:406-422`)
calls `edge.from?.removeOutgoingEdge(edge)`, so the shared upstream `Stored`'s
`outgoingEdges` went from 2 to 1 without the port doing anything.

One caveat for the port's DEBUG-configuration tests: `NodeStore.register`
(`NodeStore.swift:22-28`) spawns a `Task` per node creation even when the store
is disabled. Benchmarks build in release, where `#if DEBUG` removes the call
entirely, but a debug-configuration correctness suite that creates tens of
thousands of keyed nodes will pay for it.

## 8. Corrections to spec §5.3

Everything §5.3's "Confirmed API" block quotes is accurate — every signature and
every `file:line` checks out. Four things are worth correcting or adding.

1. **The deferral mechanism is misattributed.** §5.3 fact 3 says
   `withContinuousStateGraphTracking` "re-runs its `apply` closure on the next
   event loop through `perform(didChange, isolation:)`". `perform` is
   synchronous (`withTracking.swift:75-80`: `func perform<Return>(_ box:
ClosureBox<Return>, isolation:) -> Return { box() }`). The deferral is
   `TrackingInvalidationCallback.callAsFunction()`'s `Task { … }` at
   `withTracking.swift:164-172`. The **conclusion is unchanged and confirmed**:
   tracking cannot deliver a synchronous end-of-transaction observer run.

2. **`Stored` has four convenience initializers, not two.** §5.3 mentions the
   designated one and "a convenience init with `shouldNotify { $0 != $1 }`". The
   unconstrained one at `Stored.swift:645` notifies on every assignment and is
   what a non-`Equatable` `Value` binds silently. Risk 7 names this hazard for
   `Computed`; it applies to `Stored` too, and the port's async cells are exactly
   the shape that could trip it.

3. **`Computed`'s two `rule:` overloads sit in the same type, and the memoizing
   one's doc comment is wrong.** `StateGraph.swift:376-386` still says "uses a
   comparison function that always returns `false`" above the initializer that
   uses `{ $0 == $1 }`. Anyone confirming this by reading doc comments rather
   than bodies will reach the opposite conclusion.

4. **`Value` is constrained to `SendableMetatype`,** on both `Stored` and
   `Computed`. §5.3's excerpts omit it.

And one correction of emphasis rather than fact: §5.3's "Mutation and batching"
implies the transaction is what produces one settled render per verb. It is not
— `Computed` is pull-based, so reading once is what produces one render. The
transaction is required for atomicity, staged reads, and rollback. The
distinction matters, because it means a port that forgot a `withGraphTransaction`
would still produce the right run counts while producing wrong intermediate
states.
