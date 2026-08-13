/// A declaration and value reference for asynchronously derived state.
///
/// Constructing or copying an `AsyncCog` does not create graph state or start
/// work. The declaration carries stable descriptor identity; each ``Cogs``
/// lazily creates its own state for that identity when the value is first
/// demanded. Copies therefore name the same state in one context and separate
/// state in separate contexts.
///
/// Reading an async cog is total and value-first (§5.1): `c[valueReference]`
/// returns `Value` — the last accepted success, or the declaration's resting
/// default before one exists — so async state reads in the same shape as a
/// manual or derived cog wherever only the value matters. The request
/// lifecycle is read through the `meta` lens on the same capability
/// (`c.meta[valueReference]`), which returns the full ``CogMeta``.
///
/// Demand may come from a tracked value or metadata read, one-shot `peek`, or
/// `refresh`. Initial demand establishes
/// ``CogMeta/pending(value:hasSucceeded:)`` with the resting default and
/// `hasSucceeded == false`, then starts the selected work. A value read returns
/// that default, a metadata read returns pending, and `refresh` returns an
/// exact-generation ``CogRefresh``. Cog records pending as a graph-owned turn, but
/// if demand occurs while a selector or reaction is being evaluated, it
/// defers that turn's flush until evaluation exits. Observation and reactions
/// therefore cannot reenter the consumer that caused initial demand. Each later
/// pending, success, or failure is likewise a separate, ordered graph turn.
///
/// The `whileObserved` lifetime releases unobserved state after the
/// context's renewable grace period and cancels pending work. Each transient
/// demand replaces the state's one outstanding grace sleeper; it does not retain
/// work until completion.
///
/// The selector itself is synchronous and MainActor-isolated. Reads made with
/// its ``Reader`` become dependencies before the selector returns ``Work``;
/// reads performed later by the async operation are ordinary Swift reads and
/// do not join the graph.
@MainActor
public struct AsyncCog<Value> {
  /// Stable declaration identity and behavior shared by copies of this reference.
  internal let descriptor: AsyncCogDescriptor<Value>

  /// Stable derived-declaration identity for the total value projection.
  ///
  /// Value reads of this reference resolve through this derived declaration:
  /// its selector reads the async state's metadata and extracts its total
  /// value, which already rests on the declaration default before success.
  /// One projection descriptor is shared by every copy and — through boxes —
  /// every key, exactly like `descriptor` itself.
  internal let valueDescriptor: DerivedCogDescriptor<Value>

  /// The state-identity key, or `nil` for this keyless public declaration.
  internal let key: AnyHashable?

  /// Declares one keyless asynchronous value with an explicit resting default.
  ///
  /// The declaration is inert until a context first demands it. Under the
  /// `.latest` policy, a dependency change or refresh cancels the prior task,
  /// advances the state's generation, and accepts a completion only from the
  /// newest generation. Cancellation is advisory: even if old work ignores
  /// it and finishes, its value cannot overwrite newer state, and replacement
  /// cancellation does not become failure metadata.
  ///
  /// The selector runs on the MainActor whenever Cog needs a fresh operation.
  /// Returning ``Work`` closes dependency capture before that operation can
  /// suspend. An unannotated operation inherits the selector's MainActor;
  /// explicitly `@concurrent` work may run on the generic executor, while Cog
  /// still publishes its result on the MainActor.
  ///
  /// - Parameters:
  ///   - policy: How new work interacts with an in-flight run. `.latest` is
  ///     currently the only policy and is therefore the default.
  ///   - default: The honest resting value a value read returns before any
  ///     generation succeeds. Choose one that renders truthfully while work is
  ///     in flight; when no such value exists, make `Value` optional and pass
  ///     `nil` explicitly.
  ///   - name: A stable label for turns, diagnostics, and task tools. When
  ///     omitted, Cog derives one from the declaration site.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: Synchronous dependency selection that returns a fresh async
  ///     operation for each generation.
  public init(
    _ policy: LatestPolicy = .latest,
    default defaultValue: Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogMeta<Value>>) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let descriptor = AsyncCogDescriptor(
      policy: policy,
      default: defaultValue,
      selector: { c, _ in selector(c) },
      lifetime: .whileObserved(grace: nil),
      label: label
    )
    self.init(
      descriptor: descriptor,
      valueDescriptor: Self.makeValueDescriptor(
        for: descriptor,
        equals: nil,
        lifetime: .whileObserved(grace: nil),
        label: label
      ),
      key: nil
    )
  }

  /// Builds a value reference for an existing declaration-and-key identity.
  ///
  /// Boxes use this path so repeated subscripting remains lightweight and all
  /// keys share their box's two declaration descriptors. No context state is
  /// created here.
  internal init(
    descriptor: AsyncCogDescriptor<Value>,
    valueDescriptor: DerivedCogDescriptor<Value>,
    key: AnyHashable?
  ) {
    self.descriptor = descriptor
    self.valueDescriptor = valueDescriptor
    self.key = key
  }

  /// The derived reference every value spelling of this async cog reads.
  ///
  /// This is the internal seam that makes `c[asyncCog]` an ordinary derived
  /// read: same settlement, equality gating, lifetime, and release behavior
  /// as any other derived state, with the async state reachable through the
  /// projection's dependency edge. A value-only consumer therefore releases
  /// the projection and its async dependency at one shared grace deadline.
  internal var valueCog: Cog<Value> {
    Cog(descriptor: valueDescriptor, key: key)
  }

  /// Builds the one value-projection declaration shared by every matching
  /// value reference.
  ///
  /// The projection retains the async descriptor so its selector can resolve
  /// the same key in each context. When `Value` is itself optional, a retained
  /// successful `nil` still reads as `nil`, while the metadata's
  /// `hasSucceeded` flag preserves "succeeded with nothing" distinctly from
  /// the resting default. `equals` applies only to the projected value; the async state's metadata
  /// publication remains independent.
  internal static func makeValueDescriptor(
    for descriptor: AsyncCogDescriptor<Value>,
    equals: (@MainActor (Value, Value) -> Bool)?,
    lifetime: CogStateLifetime,
    label: CogLabel
  ) -> DerivedCogDescriptor<Value> {
    DerivedCogDescriptor(
      selector: { c, key in
        c.asyncMeta(from: descriptor, key: key).value
      },
      equals: equals,
      lifetime: lifetime,
      label: CogLabel(
        name: "\(label).value",
        fileID: label.fileID,
        line: label.line
      )
    )
  }
}

extension AsyncCog where Value: Equatable {
  /// Declares one keyless async value with equality-gated value reads and an
  /// explicit resting default.
  ///
  /// This overload has the same scheduling, cancellation, actor, and lifetime
  /// behavior as the unconstrained initializer. The added `Equatable` rule is
  /// intentionally narrow: when work succeeds with an equal value, value
  /// consumers remain quiet, while metadata consumers still observe pending
  /// and success as distinct turns.
  ///
  /// - Parameters:
  ///   - policy: The replacement policy for in-flight work. Only `.latest` is
  ///     currently available.
  ///   - default: The honest resting value returned before the first success.
  ///   - name: A stable label for turns, diagnostics, and task tools.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection that returns one async
  ///     operation per generation.
  public init(
    _ policy: LatestPolicy = .latest,
    default defaultValue: Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogMeta<Value>>) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let descriptor = AsyncCogDescriptor(
      policy: policy,
      default: defaultValue,
      selector: { c, _ in selector(c) },
      lifetime: .whileObserved(grace: nil),
      label: label
    )
    self.init(
      descriptor: descriptor,
      valueDescriptor: Self.makeValueDescriptor(
        for: descriptor,
        equals: { oldValue, newValue in oldValue == newValue },
        lifetime: .whileObserved(grace: nil),
        label: label
      ),
      key: nil
    )
  }
}
