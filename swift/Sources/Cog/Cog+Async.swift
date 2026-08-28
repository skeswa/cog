extension Cog {
  /// A declaration and value reference for asynchronously automatic state.
  ///
  /// Constructing or copying a `Cog.Async` does not create graph state or start
  /// work. The declaration carries stable descriptor identity; each ``Cogs``
  /// lazily creates its own state for that identity when the value is first
  /// demanded. Copies therefore name the same state in one context and separate
  /// state in separate contexts.
  ///
  /// Name a keyless declaration with `Cog` as its final word, such as
  /// `forecastCog`; values read from it keep ordinary unsuffixed domain names.
  ///
  /// Reading an async cog is total and value-first (§5.1). `c[valueReference]`
  /// returns the last accepted success or the resting default before one
  /// exists. Code that needs only the value can read it like a manual or
  /// automatic cog. The request
  /// lifecycle is read through the `status` lens on the same capability
  /// (`c.status[valueReference]`), which returns the full ``CogStatus``.
  /// Bind either form to the declaration's unsuffixed domain name before use;
  /// even a full status read is `let forecast = c.status[forecastCog]`, not
  /// `forecastStatus`.
  ///
  /// Demand may come from a tracked value or status read, one-shot `peek`, or
  /// `refresh`. Initial demand establishes
  /// ``CogStatus/kind`` at ``CogStatus/Kind/pending`` with the
  /// resting default and `hasSucceeded == false`, then starts the selected work.
  /// A value read returns that default, a status read returns those atomic fields,
  /// and `refresh` returns an
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
  public struct Async {
    /// Stable declaration identity and behavior shared by copies of this reference.
    internal let descriptor: AsyncCogDescriptor<Value>

    /// Stable declaration for this async value's plain value read.
    ///
    /// Its selector reads the async status and returns its total value, which
    /// uses the declaration default before success. Every copy and box key
    /// shares this descriptor.
    internal let valueDescriptor: AutomaticCogDescriptor<Value>

    /// The state-identity key, or `nil` for this keyless public declaration.
    internal let key: CogKey?

    /// Declares one keyless asynchronous value with an explicit resting default.
    ///
    /// The declaration is inert until a context first demands it. Under the
    /// `.latest` policy, a dependency change or refresh cancels the prior task,
    /// advances the state's generation, and accepts a completion only from the
    /// newest generation. Cancellation is advisory: even if old work ignores
    /// it and finishes, its value cannot overwrite newer state, and replacement
    /// cancellation does not become failure status.
    ///
    /// The selector runs on the MainActor whenever Cog needs a fresh operation.
    /// Returning ``Work`` closes dependency capture before that operation can
    /// suspend. An unannotated operation inherits the selector's MainActor;
    /// explicitly `@concurrent` work may run on the generic executor, while Cog
    /// still publishes its result on the MainActor.
    ///
    /// - Parameters:
    ///   - policy: Latest-generation replacement for one-shot or stream work.
    ///     Omit it for the default `.latest` spelling; ordered policies use the
    ///     separate ``RunWork`` initializer.
    ///   - defaultValue: The honest resting value a value read returns before any
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
      default defaultValue: @autoclosure @escaping @MainActor () -> Value,
      name: String? = nil,
      fileID: StaticString = #fileID,
      line: UInt = #line,
      _ selector: @escaping @MainActor (Reader<CogStatus<Value>>) -> Work<Value>
    ) {
      let label = CogLabel(name: name, fileID: fileID, line: line)
      let descriptor = AsyncCogDescriptor(
        policy: policy.schedulingPolicy,
        default: defaultValue,
        equals: nil,
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

    /// Declares one keyless one-shot async value with an ordered policy.
    ///
    /// Ordered policies cannot describe streams: the selector must return
    /// ``RunWork``, whose only factory is ``RunWork/run(_:)``. This type boundary
    /// rejects invalid work before a context exists while preserving the same
    /// lazy declaration identity, dependency capture, lifetime, and status model
    /// as the latest-policy initializer.
    ///
    /// - Parameters:
    ///   - policy: Queue, exhaust-latest, or merged scheduling for one-shot runs.
    ///   - defaultValue: The honest resting value before any run succeeds.
    ///     Evaluated once per state, not once per declaration.
    ///   - name: A stable label for turns, diagnostics, and task tools.
    ///   - fileID: The declaration's file. Leave this at its default.
    ///   - line: The declaration's line. Leave this at its default.
    ///   - selector: MainActor dependency selection that returns one run.
    public init(
      _ policy: OrderedPolicy,
      default defaultValue: @autoclosure @escaping @MainActor () -> Value,
      name: String? = nil,
      fileID: StaticString = #fileID,
      line: UInt = #line,
      _ selector: @escaping @MainActor (Reader<CogStatus<Value>>) -> RunWork<Value>
    ) {
      let label = CogLabel(name: name, fileID: fileID, line: line)
      let descriptor = AsyncCogDescriptor(
        policy: policy.schedulingPolicy,
        default: defaultValue,
        equals: nil,
        selector: { c, _ in Work(selector(c)) },
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
      valueDescriptor: AutomaticCogDescriptor<Value>,
      key: CogKey?
    ) {
      self.descriptor = descriptor
      self.valueDescriptor = valueDescriptor
      self.key = key
    }

    /// The automatic reference every value spelling of this async cog reads.
    ///
    /// This makes `c[asyncCog]` a normal automatic read with the same settlement,
    /// equality, lifetime, and release rules. Its dependency edge reaches the
    /// async state, so a value-only consumer releases both states at one grace
    /// deadline.
    internal var valueCog: Cog<Value> {
      Cog(descriptor: valueDescriptor, key: key)
    }

    /// Builds the one value-projection declaration shared by every matching
    /// value reference.
    ///
    /// The projection retains the async descriptor so its selector can resolve
    /// the same key in each context. When `Value` is itself optional, a retained
    /// successful `nil` still reads as `nil`, while the status's
    /// `hasSucceeded` flag preserves "succeeded with nothing" distinctly from
    /// the resting default. `equals` applies only to the projected value; the async state's status
    /// publication remains independent.
    internal static func makeValueDescriptor(
      for descriptor: AsyncCogDescriptor<Value>,
      equals: (@MainActor (Value, Value) -> Bool)?,
      lifetime: CogStateLifetime,
      label: CogLabel
    ) -> AutomaticCogDescriptor<Value> {
      AutomaticCogDescriptor(
        selector: { c, key in
          c.asyncStatus(from: descriptor, key: key).value
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
}

extension Cog.Async where Value: Equatable {
  /// Declares one keyless async value with equality-gated value reads and an
  /// explicit resting default.
  ///
  /// This overload has the same scheduling, cancellation, actor, and lifetime
  /// behavior as the unconstrained initializer. The added `Equatable` rule is
  /// intentionally narrow: when work succeeds with an equal value, value
  /// consumers remain quiet, while status consumers still observe pending
  /// and success as distinct turns.
  ///
  /// - Parameters:
  ///   - policy: Latest-generation replacement for one-shot or stream work.
  ///     Ordered policies use the separate ``RunWork`` initializer.
  ///   - defaultValue: The honest resting value returned before the first
  ///     success. Evaluated once per state, not once per declaration.
  ///   - name: A stable label for turns, diagnostics, and task tools.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection that returns one async
  ///     operation per generation.
  public init(
    _ policy: LatestPolicy = .latest,
    default defaultValue: @autoclosure @escaping @MainActor () -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogStatus<Value>>) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let descriptor = AsyncCogDescriptor(
      policy: policy.schedulingPolicy,
      default: defaultValue,
      equals: { oldValue, newValue in oldValue == newValue },
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

  /// Declares an equality-gated one-shot async value with an ordered policy.
  ///
  /// This overload combines ``RunWork``'s compile-time stream exclusion with
  /// the ordinary `Equatable` value projection. Equal successes may still be
  /// visible as lifecycle transitions while value consumers remain quiet.
  ///
  /// - Parameters:
  ///   - policy: Queue, exhaust-latest, or merged scheduling for one-shot runs.
  ///   - defaultValue: The honest resting value before any run succeeds.
  ///     Evaluated once per state, not once per declaration.
  ///   - name: A stable label for turns, diagnostics, and task tools.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection that returns one run.
  public init(
    _ policy: OrderedPolicy,
    default defaultValue: @autoclosure @escaping @MainActor () -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogStatus<Value>>) -> RunWork<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let descriptor = AsyncCogDescriptor(
      policy: policy.schedulingPolicy,
      default: defaultValue,
      equals: { oldValue, newValue in oldValue == newValue },
      selector: { c, _ in Work(selector(c)) },
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
