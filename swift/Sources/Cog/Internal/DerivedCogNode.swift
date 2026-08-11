/// The live state behind one ``Cog`` ref, in one context.
///
/// A derived node is the other half of ``ManualCogNode``: nothing writes it,
/// and everything about it comes from running its declaration's selector. That
/// run is what makes it lazy and what makes it cacheable — the two behaviors
/// this node exists to provide (§2.2).
///
/// **Lazy.** The node computes nothing when it is created. A declaration is a
/// name, and an app that declares a hundred derived values and reads three
/// should run three selectors. The first read is what runs the selector, and
/// a node that is never read never runs at all (`DECL-09`).
///
/// **Cached.** A run's value is kept, so a second read is a lookup rather than
/// a second run (`READ-02`). Keeping a value is only correct while nothing it
/// was computed from has changed, and *noticing* that change is the settle
/// engine's job (`M1-06aa`, `M1-06ab`), which does not exist yet. Until it
/// does, a write to a source that a derived cog already computed from leaves
/// this node holding the value it computed before the write. That is a known,
/// deliberate hole in this slice of the ledger, not a behavior anything should
/// rely on: `M1-06aa` adds CLEAN/CHECK/DIRTY and versions, and this cache
/// becomes valid only while the node is clean.
///
/// The dependencies a run captured are recorded even though nothing consumes
/// them yet, because they are captured *by the run* (§2.4) and there is no
/// second chance to collect them later. `M1-06aa` reads them to walk parents,
/// and `M1-09a` makes recapture across conditionals and early returns
/// observable.
internal final class DerivedCogNode<Value>: CogNode, CogConsumer {
  /// The declaration this node belongs to.
  let descriptor: DerivedCogDescriptor<Value>

  /// Which node of `descriptor` this is, or `nil` for a keyless declaration.
  ///
  /// Keyless today; `M1-05b`'s derived boxes are what make it interesting. The
  /// node knows its own key so a diagnostic can name it — `isNiceOutside[90210]`
  /// rather than `isNiceOutside` — without a reverse lookup through the
  /// context's storage (§2.4).
  let key: AnyHashable?

  /// What the last run of the selector produced, or `.none` if it has never
  /// run in this context.
  ///
  /// This optional is storage presence, not value optionality, the same
  /// distinction ``ManualCogNode/pendingValue`` makes. When `Value` is itself
  /// optional, `.some(.none)` means a run really did produce nil — which must
  /// hit the cache, not run the selector a second time.
  internal private(set) var cachedValue: Value?

  /// The producers the last run read through `c.get`, in read order.
  ///
  /// Rebuilt from empty on every run, because dependencies are exactly what
  /// this run read (§2.4) and an edge that is not read again is not an edge.
  /// A list, with repeats left in, is the correctness build's answer: reusing
  /// edges, removing dropped ones, and the physical layout are all
  /// benchmark-gated (perf §3.3) and belong to `M1-06aa` and `M6`.
  internal private(set) var dependencies: [any CogNode] = []

  var label: CogLabel { descriptor.label }

  /// Whether the selector has run in this context yet.
  ///
  /// Named separately from the cache so that a caller asking the lazy question
  /// does not have to know how the answer is stored.
  var hasComputed: Bool {
    if case .some = cachedValue {
      return true
    }
    return false
  }

  /// Creates the node without computing anything.
  init(descriptor: DerivedCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
    self.cachedValue = .none
  }

  /// The node's value, running the selector if this is its first read.
  ///
  /// Every read of a derived cog goes through here — tracked or untracked,
  /// from a selector or from outside one — so that no caller can spell a read
  /// that skips the computation. `M1-06aa` adds the settle check to the same
  /// choke point, which is why it is stated as "settled value" rather than
  /// "cached value or run".
  func settledValue(in cogs: Cogtext) -> Value {
    if case .some(let cached) = cachedValue {
      return cached
    }
    return run(in: cogs)
  }

  func recordDependency(on producer: any CogNode) {
    dependencies.append(producer)
  }

  /// Runs the selector once, tracking what it reads, and keeps the result.
  ///
  /// The node installs itself as the context's tracked consumer for the
  /// duration of the run, so a nested read of another derived cog computes
  /// that cog against *itself* and hands tracking back on the way out.
  private func run(in cogs: Cogtext) -> Value {
    dependencies.removeAll(keepingCapacity: true)

    let value = cogs.tracking(self) {
      descriptor.compute(Reader(cogs: cogs, node: self))
    }

    cachedValue = .some(value)
    return value
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}
