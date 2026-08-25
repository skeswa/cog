internal import StateGraph
import Testing

@testable import StorefrontStateGraph

/// Proof that this port's derived nodes actually memoize.
///
/// The most dangerous thing about swift-state-graph 0.28.0 for a port like this
/// one is silent and has no diagnostic. `Computed` has two `rule:` initializers
/// in the same type with the same argument labels; the constrained one
/// (`StateGraph.swift:387`) installs `isEqual: { $0 == $1 }` and the
/// unconstrained one (`StateGraph.swift:357`) installs
/// `isEqual: { _, _ in false }`, which marks every outgoing edge pending on
/// every recomputation. A `Value` that is not `Equatable` at the call site binds
/// the second one, compiles, produces correct answers, and turns that branch of
/// the graph into a recompute-on-read floor — so the comparison would be
/// reporting a number about a port nobody meant to write. The library's own doc
/// comment on the memoizing initializer still describes the non-memoizing
/// behavior, so reading comments rather than bodies reaches the opposite
/// conclusion.
///
/// The port answers that structurally: `makeMemoizedComputed(_:_:)` carries a
/// `Value: Equatable` constraint, so inside it the memoizing initializer is the
/// only applicable overload, and every derived node in the port is built
/// through it. This suite refuses to take that on trust. It builds the probe's
/// shape — an upstream that changes, a middle rule that maps the change to an
/// **equal** value, and a leaf that counts its own invocations — through the
/// port's own constructor, and then builds the same shape a second time through
/// an explicitly non-memoizing descriptor to prove the instrument can tell the
/// two apart. Without that control, a leaf that ran once would be evidence of
/// nothing.
///
/// This is an infrastructure suite and it greens no checkpoint, which is why it
/// is the one place in this package that reaches for `@testable` and for the
/// library's own types.
@Suite("swift-state-graph memoization")
@MainActor
struct StorefrontStateGraphMemoizationTests {
  /// A rule-invocation tally shared with a `@Sendable` computation rule.
  ///
  /// `Computed`'s rule is `@Sendable`, so the counter cannot be a captured
  /// local. Every read in this suite happens from one test on the MainActor, so
  /// the unchecked conformance is sound here and only here.
  ///
  /// `nonisolated deinit` per the repository convention: under
  /// `.defaultIsolation(MainActor.self)` a synthesized deinit would ask the
  /// concurrency runtime which executor it is on for every deallocation.
  nonisolated final class RuleCounter: @unchecked Sendable {
    /// How many times the rule this counter is attached to has run.
    private(set) var count = 0

    /// Records one rule invocation.
    func bump() { count += 1 }

    nonisolated deinit {}
  }

  /// A derived value that is equal across an upstream change must not reach its
  /// dependents.
  ///
  /// The exact shape probe `a2` in `API-NOTES.md` uses, built through the
  /// constructor every node in this port is built through. `source` moves from
  /// 2 to 4; `middle` recomputes and produces the same `0` both times; `leaf`
  /// must therefore have run exactly once. A non-memoizing binding would run it
  /// twice.
  @Test("an equal derived value does not propagate")
  func equalDerivedValueDoesNotPropagate() {
    let source = makeSource("memo.source", 2)
    let middleRuns = RuleCounter()
    let leafRuns = RuleCounter()

    let middle = makeMemoizedComputed("memo.middle") {
      middleRuns.bump()
      return source.wrappedValue % 2
    }
    let leaf = makeMemoizedComputed("memo.leaf") {
      leafRuns.bump()
      return middle.wrappedValue + 100
    }

    #expect(leaf.wrappedValue == 100)
    #expect(middleRuns.count == 1)
    #expect(leafRuns.count == 1)

    // A genuine upstream change that the middle rule maps to an equal value.
    source.wrappedValue = 4
    #expect(leaf.wrappedValue == 100)
    #expect(middleRuns.count == 2, "the middle rule must recompute: its own input changed")
    #expect(
      leafRuns.count == 1,
      """
      The leaf recomputed even though the middle produced an equal value, which means the port's \
      node constructor bound Computed's non-memoizing rule: initializer. Every derived value in \
      this port must be Equatable at the point the node is built.
      """
    )

    // And a change the middle rule maps to a different value must propagate,
    // so the assertion above is about memoization rather than about a graph
    // that never propagates anything.
    source.wrappedValue = 5
    #expect(leaf.wrappedValue == 101)
    #expect(leafRuns.count == 2)
  }

  /// The instrument is sensitive: it reports two when memoization is off.
  ///
  /// The control for the test above. The same shape is built with a middle node
  /// whose descriptor is explicitly `isEqual: { _, _ in false }` — which is what
  /// `Computed`'s unconstrained `rule:` initializer installs — and the leaf must
  /// run twice. Without this, "the leaf ran once" could be true for a
  /// structural reason and would prove nothing about the binding.
  @Test("the instrument reports a non-memoizing middle as two leaf runs")
  func instrumentDetectsANonMemoizingMiddle() {
    let source = makeSource("memo.control.source", 2)
    let leafRuns = RuleCounter()

    let middle = Computed<Int>(
      name: "memo.control.middle",
      descriptor: AnyComputedDescriptor<Int>(
        compute: { _ in source.wrappedValue % 2 },
        isEqual: { _, _ in false }
      )
    )
    let leaf = makeMemoizedComputed("memo.control.leaf") {
      leafRuns.bump()
      return middle.wrappedValue + 100
    }

    #expect(leaf.wrappedValue == 100)
    #expect(leafRuns.count == 1)

    source.wrappedValue = 4
    #expect(leaf.wrappedValue == 100)
    #expect(
      leafRuns.count == 2,
      "the instrument cannot distinguish the two Computed overloads, so the test above is blind"
    )
  }

  /// A source assignment equal to the current value must invalidate nothing.
  ///
  /// The other half of the same hazard, one layer up. `Stored` has *four*
  /// convenience initializers and the unconstrained one
  /// (`Stored.swift:645`) installs `shouldNotify: { _, _ in true }`, so a source
  /// whose `Value` is not `Equatable` notifies on every assignment. The port
  /// builds every source through `makeSource(_:_:)`, whose `Value: Equatable`
  /// constraint makes the gated initializer the only applicable one — which is
  /// what ``StorefrontRuntimeSemantics/browseRunsPerEqualWrite`` of zero rests
  /// on.
  @Test("an equal source assignment invalidates nothing")
  func equalSourceAssignmentInvalidatesNothing() {
    let source = makeSource("memo.gate.source", 1)
    let derivedRuns = RuleCounter()
    let derived = makeMemoizedComputed("memo.gate.derived") {
      derivedRuns.bump()
      return source.wrappedValue * 2
    }

    #expect(derived.wrappedValue == 2)
    #expect(derivedRuns.count == 1)

    source.wrappedValue = 1
    #expect(derived.wrappedValue == 2)
    #expect(derivedRuns.count == 1, "an equal write reached the graph, so the source is ungated")

    source.wrappedValue = 2
    #expect(derived.wrappedValue == 4)
    #expect(derivedRuns.count == 2)
  }
}
