/// A declaration and value reference for asynchronously derived state.
///
/// Constructing or copying an `AsyncCog` does not create graph state or start
/// work. The declaration carries stable descriptor identity; each ``Cogtext``
/// lazily creates its own state for that identity when the value is first
/// demanded. Copies therefore name the same state in one context and separate
/// state in separate contexts.
///
/// Demand may come from a tracked read, one-shot `peek`, or `refresh`. Initial
/// demand establishes ``CogPhase/pending(previous:)`` with ``Previous/none``
/// synchronously and starts the selected work; a read returns that phase, while
/// `refresh` returns no value. Cog records pending as a graph-owned turn, but if
/// demand occurs while a selector or reaction is being evaluated, it
/// defers that turn's flush until evaluation exits. Observation and reactions
/// therefore cannot reenter the consumer that caused initial demand. Each later
/// pending, success, or failure is likewise a separate, ordered graph turn.
///
/// The default `whileObserved` lifetime releases unobserved state after the
/// context's renewable grace period and cancels pending work. Each transient
/// demand replaces the state's one outstanding grace sleeper; it does not retain
/// work until completion. `keepAlive` instead retains the state for the context
/// lifetime.
///
/// The selector itself is synchronous and MainActor-isolated. Reads made with
/// its ``Reader`` become dependencies before the selector returns ``Work``;
/// reads performed later by the async operation are ordinary Swift reads and
/// do not join the graph.
@MainActor
public struct AsyncCog<Value> {
  /// Stable declaration identity and behavior shared by copies of this reference.
  internal let descriptor: AsyncCogDescriptor<Value>

  /// Stable derived-declaration identity shared by copies of ``latest``.
  internal let latestDescriptor: DerivedCogDescriptor<Value?>

  /// The state-identity key, or `nil` for this keyless public declaration.
  internal let key: AnyHashable?

  /// Declares one keyless asynchronous value.
  ///
  /// The declaration is inert until a context first demands it. Under the
  /// `.latest` policy, a dependency change or refresh cancels the prior task,
  /// advances the state's generation, and accepts a completion only from the
  /// newest generation. Cancellation is advisory: even if old work ignores
  /// it and finishes, its value cannot overwrite newer state, and replacement
  /// cancellation does not become a failure phase.
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
  ///   - keepAlive: Pass `true` to retain this state until its context ends.
  ///     The default releases it after its last durable consumer and grace
  ///     period. A one-shot demand renews grace without becoming a consumer.
  ///   - name: A stable label for turns, diagnostics, and task tools. When
  ///     omitted, Cog derives one from the declaration site.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: Synchronous dependency selection that returns a fresh async
  ///     operation for each generation.
  public init(
    _ policy: LatestPolicy = .latest,
    keepAlive: Bool = false,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogPhase<Value>>) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let descriptor = AsyncCogDescriptor(
      policy: policy,
      selector: { c, _ in selector(c) },
      lifetime: CogStateLifetime(keepAlive: keepAlive),
      label: label
    )
    self.init(
      descriptor: descriptor,
      latestDescriptor: Self.makeLatestDescriptor(
        for: descriptor,
        equals: nil,
        lifetime: CogStateLifetime(keepAlive: keepAlive),
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
    latestDescriptor: DerivedCogDescriptor<Value?>,
    key: AnyHashable?
  ) {
    self.descriptor = descriptor
    self.latestDescriptor = latestDescriptor
    self.key = key
  }
  /// A derived value reference for the last successful value, if any.
  ///
  /// This projection deliberately erases loading and error details so code
  /// that needs them should read the `AsyncCog` itself. It returns `nil` until
  /// the first success, returns that success during later pending and failure
  /// phases, and updates on a new success.
  ///
  /// `latest` is a stable derived declaration, not a snapshot: repeated access
  /// produces references with the same descriptor-and-key identity. Its state
  /// follows the async declaration's lifetime, and a latest-only consumer
  /// releases the projection and async dependency at one shared grace
  /// deadline. When `Value` is `Equatable`, equal latest values stop the
  /// projection's downstream wave even though full-phase consumers still see
  /// the async phase turns. Reading this projection creates demand for the same
  /// async state and participates in the caller's normal selector, reaction, or
  /// Observation tracking; accessing the property alone is inert.
  ///
  /// - Returns: A stable derived reference whose value is the most recent
  ///   success, or `nil` when this async state has never succeeded.
  public var latest: Cog<Value?> {
    Cog(descriptor: latestDescriptor, key: key)
  }

  /// Builds the one projection declaration shared by every matching value reference.
  ///
  /// The projection retains the async descriptor so its selector can resolve
  /// the same key in each context. `equals` applies only to the projected
  /// optional value; the async state's phase publication remains independent.
  internal static func makeLatestDescriptor(
    for descriptor: AsyncCogDescriptor<Value>,
    equals: (@MainActor (Value?, Value?) -> Bool)?,
    lifetime: CogStateLifetime,
    label: CogLabel
  ) -> DerivedCogDescriptor<Value?> {
    DerivedCogDescriptor(
      selector: { c, key in
        c.asyncPhase(from: descriptor, key: key).latestValue
      },
      equals: equals,
      lifetime: lifetime,
      label: CogLabel(
        name: "\(label).latest",
        fileID: label.fileID,
        line: label.line
      )
    )
  }
}

extension AsyncCog where Value: Equatable {
  /// Declares one keyless async value with equality-gated ``latest`` updates.
  ///
  /// This overload has the same scheduling, cancellation, actor, and lifetime
  /// behavior as the unconstrained initializer. The added `Equatable` rule is
  /// intentionally narrow: when work succeeds with the same latest value,
  /// consumers of `latest` remain quiet, while consumers of the full
  /// ``CogPhase`` still observe pending and success as distinct turns.
  ///
  /// - Parameters:
  ///   - policy: The replacement policy for in-flight work. Only `.latest` is
  ///     currently available.
  ///   - keepAlive: Whether state survives without a consumer until the
  ///     context ends instead of following `whileObserved` grace.
  ///   - name: A stable label for turns, diagnostics, and task tools.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection that returns one async
  ///     operation per generation.
  public init(
    _ policy: LatestPolicy = .latest,
    keepAlive: Bool = false,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogPhase<Value>>) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let descriptor = AsyncCogDescriptor(
      policy: policy,
      selector: { c, _ in selector(c) },
      lifetime: CogStateLifetime(keepAlive: keepAlive),
      label: label
    )
    self.init(
      descriptor: descriptor,
      latestDescriptor: Self.makeLatestDescriptor(
        for: descriptor,
        equals: { oldValue, newValue in oldValue == newValue },
        lifetime: CogStateLifetime(keepAlive: keepAlive),
        label: label
      ),
      key: nil
    )
  }
}
