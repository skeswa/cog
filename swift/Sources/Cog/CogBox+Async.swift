extension CogBox {
  /// A family of asynchronously automatic values sharing one declaration.
  ///
  /// A box owns one declaration descriptor and builds lightweight ``Cog/Async``
  /// value references for its keys. Each descriptor-and-key pair has its own
  /// status, dependencies, generation, lifetime state, and work task in a
  /// ``Cogs``:
  ///
  /// ```swift
  /// let fetchedWeatherCogs = CogBox<Weather?, ZipCode>.Async(
  ///   default: nil,
  ///   name: "weather.fetch"
  /// ) {
  ///   c, zip in
  ///   let weatherService = c[weatherServiceCog]
  ///   return .run { try await weatherService.weather(for: zip) }
  /// }
  /// ```
  ///
  /// The plural final `Cogs` suffix distinguishes this box from the individual
  /// ``Cog/Async`` value references it produces.
  ///
  /// Value reads of a key are total: `c[fetchedWeatherCogs[zip]]` returns the last
  /// accepted success for that key, resting on the declaration's explicit
  /// default until one exists. Each
  /// key's full request lifecycle reads through the `status` lens,
  /// `c.status[fetchedWeatherCogs[zip]]`.
  ///
  /// Building `box[key]` creates no state and allocates no new descriptor. Equal
  /// keys produce the same declaration-and-key identity, while unequal keys are
  /// independent even though they share selector code, policy, and default. A
  /// context creates a key's state only when that reference is first demanded;
  /// another context creates separate state for the same key.
  ///
  /// The box and its selector are MainActor-isolated. The selector finishes
  /// dependency capture before returning ``Work``. Each key's work then follows
  /// the actor context chosen by that `Work`, and Cog publishes completions back
  /// on the MainActor. Initial demand establishes pending synchronously for that
  /// key. If it happens inside a selector or reaction, Cog defers the
  /// graph-owned pending flush until that evaluation finishes rather than
  /// reentering it.
  @MainActor
  public struct Async {
    /// Stable async-declaration identity shared by all keys and box copies.
    internal let descriptor: AsyncCogDescriptor<Value>

    /// Stable value-projection identity shared by all keys and box copies.
    internal let valueDescriptor: AutomaticCogDescriptor<Value>

    /// Declares a keyed async automatic value with an explicit resting default.
    ///
    /// This creates one async descriptor and one value-projection descriptor,
    /// regardless of how many keys are later used. The synchronous selector runs
    /// separately whenever one key needs a new generation. Its tracked reads are
    /// dependencies of that key only; sibling keys neither invalidate nor
    /// replace one another unless the selector explicitly makes them share a
    /// dependency.
    ///
    /// Initial demand for a key publishes pending with `default` and
    /// `hasSucceeded == false`; that key's value read rests on the same default
    /// until its first success. Under
    /// `.latest`, a reload cancels and supersedes only that key's prior task, and
    /// a stale completion cannot publish. By default, each unobserved key is
    /// released independently after grace and pending work is cancelled.
    ///
    /// - Parameters:
    ///   - policy: Latest-generation replacement for one key's one-shot or
    ///     stream work. Ordered policies use the separate ``RunWork``
    ///     initializer. Sibling keys never replace one another's work.
    ///   - defaultValue: The honest resting value every key's value read returns
    ///     before that key's first success. Choose one that renders truthfully
    ///     while work is in flight; when no such value exists, make `Value`
    ///     optional and pass `nil` explicitly.
    ///   - name: What Cog should call this declaration in turns, diagnostics,
    ///     and task tools. A rendered keyed name includes the key.
    ///   - fileID: The declaration's file. Leave this at its default.
    ///   - line: The declaration's line. Leave this at its default.
    ///   - selector: MainActor dependency selection for one key, returning a
    ///     fresh async operation for that key's next generation.
    public init(
      _ policy: LatestPolicy = .latest,
      default defaultValue: @autoclosure @escaping @MainActor () -> Value,
      name: String? = nil,
      fileID: StaticString = #fileID,
      line: UInt = #line,
      _ selector: @escaping @MainActor (Reader<CogStatus<Value>>, Key) -> Work<Value>
    ) {
      let label = CogLabel(name: name, fileID: fileID, line: line)
      let lifetime = CogStateLifetime.whileObserved(grace: nil)
      let descriptor = Self.makeDescriptor(
        policy: policy.schedulingPolicy,
        default: defaultValue,
        equals: nil,
        lifetime: lifetime,
        label: label,
        selector: selector
      )
      self.descriptor = descriptor
      self.valueDescriptor = Cog.Async.makeValueDescriptor(
        for: descriptor,
        equals: nil,
        lifetime: lifetime,
        label: label
      )
    }

    /// Declares keyed one-shot async values with an ordered policy.
    ///
    /// Every key receives independent ordered scheduling. Requiring ``RunWork``
    /// makes `.stream` unavailable in the selector while retaining the same lazy
    /// descriptor-and-key identity, tracked dependency capture, and per-key
    /// lifetime as the latest-policy initializer.
    ///
    /// - Parameters:
    ///   - policy: Queue, exhaust-latest, or merged scheduling per key.
    ///   - defaultValue: The honest resting value before a key first succeeds.
    ///   - name: A stable declaration label; rendered labels include the key.
    ///   - fileID: The declaration's file. Leave this at its default.
    ///   - line: The declaration's line. Leave this at its default.
    ///   - selector: MainActor dependency selection returning one run for a key.
    public init(
      _ policy: OrderedPolicy,
      default defaultValue: @autoclosure @escaping @MainActor () -> Value,
      name: String? = nil,
      fileID: StaticString = #fileID,
      line: UInt = #line,
      _ selector: @escaping @MainActor (Reader<CogStatus<Value>>, Key) -> RunWork<Value>
    ) {
      let label = CogLabel(name: name, fileID: fileID, line: line)
      let lifetime = CogStateLifetime.whileObserved(grace: nil)
      let descriptor = Self.makeDescriptor(
        policy: policy.schedulingPolicy,
        default: defaultValue,
        equals: nil,
        lifetime: lifetime,
        label: label,
        selector: { c, key in Work(selector(c, key)) }
      )
      self.descriptor = descriptor
      self.valueDescriptor = Cog.Async.makeValueDescriptor(
        for: descriptor,
        equals: nil,
        lifetime: lifetime,
        label: label
      )
    }

    /// The value reference naming this box's async value for one key.
    ///
    /// Equal keys name the same state. Different keys fetch and advance their
    /// status independently while sharing this box's declaration descriptors.
    /// Subscripting is inert: the returned reference creates state and starts
    /// work only when a context reads, peeks, or refreshes it.
    ///
    /// - Parameter key: The hashable value forming the state identity together
    ///   with this box's descriptor.
    /// - Returns: A lightweight async value reference for that identity.
    public subscript(key: Key) -> Cog<Value>.Async {
      Cog.Async(
        descriptor: descriptor,
        valueDescriptor: valueDescriptor,
        key: CogKey(key)
      )
    }

    /// Builds the box's one async descriptor, wrapping the keyed selector in
    /// the erased-key resolution every state of this declaration shares.
    ///
    /// The cast trap fires only on corrupt state storage: no other code can
    /// build value references for this declaration, so an erased key of the
    /// wrong type means the context's storage itself is broken, and continuing
    /// would run the selector against an impossible identity.
    internal static func makeDescriptor(
      policy: AsyncSchedulingPolicy,
      default defaultValue: @escaping @MainActor () -> Value,
      equals: (@MainActor (Value, Value) -> Bool)?,
      lifetime: CogStateLifetime,
      label: CogLabel,
      selector: @escaping @MainActor (Reader<CogStatus<Value>>, Key) -> Work<Value>
    ) -> AsyncCogDescriptor<Value> {
      AsyncCogDescriptor(
        policy: policy,
        default: defaultValue,
        equals: equals,
        selector: { c, erasedKey in
          guard let key = erasedKey?.erased.base as? Key else {
            fatalError(
              """
              A state of \(label) was asked to make work for \
              \(String(describing: erasedKey?.erased)), which is not a \(Key.self). Only this \
              box builds value references for its own declaration, so this context's state \
              storage is corrupt.
              """
            )
          }
          return selector(c, key)
        },
        lifetime: lifetime,
        label: label
      )
    }
  }
}

extension CogBox.Async where Value: Equatable {
  /// Declares keyed async values with equality-gated value reads and an
  /// explicit resting default.
  ///
  /// Scheduling, cancellation, state identity, actor execution, and lifetime
  /// are identical to the unconstrained initializer. Equality affects only
  /// each key's value projection: status consumers still observe pending and
  /// success turns even when the successful value is unchanged.
  ///
  /// - Parameters:
  ///   - policy: Latest-generation replacement for one key's one-shot or
  ///     stream work. Ordered policies use the separate ``RunWork``
  ///     initializer.
  ///   - defaultValue: The honest resting value every key returns before its first
  ///     success.
  ///   - name: A stable declaration label; rendered keyed labels include the key.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection returning one operation for
  ///     the requested key and generation.
  public init(
    _ policy: LatestPolicy = .latest,
    default defaultValue: @autoclosure @escaping @MainActor () -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogStatus<Value>>, Key) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let lifetime = CogStateLifetime.whileObserved(grace: nil)
    let descriptor = Self.makeDescriptor(
      policy: policy.schedulingPolicy,
      default: defaultValue,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: lifetime,
      label: label,
      selector: selector
    )
    self.descriptor = descriptor
    self.valueDescriptor = Cog.Async.makeValueDescriptor(
      for: descriptor,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: lifetime,
      label: label
    )
  }

  /// Declares equality-gated keyed one-shot values with an ordered policy.
  ///
  /// ``RunWork`` enforces latest-only streams at the selector boundary, while
  /// `Equatable` suppresses unchanged value-projection notices independently
  /// for each key. Status and scheduling remain per-key graph state.
  ///
  /// - Parameters:
  ///   - policy: Queue, exhaust-latest, or merged scheduling per key.
  ///   - defaultValue: The honest resting value before a key first succeeds.
  ///   - name: A stable declaration label; rendered labels include the key.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection returning one run for a key.
  public init(
    _ policy: OrderedPolicy,
    default defaultValue: @autoclosure @escaping @MainActor () -> Value,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogStatus<Value>>, Key) -> RunWork<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let lifetime = CogStateLifetime.whileObserved(grace: nil)
    let descriptor = Self.makeDescriptor(
      policy: policy.schedulingPolicy,
      default: defaultValue,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: lifetime,
      label: label,
      selector: { c, key in Work(selector(c, key)) }
    )
    self.descriptor = descriptor
    self.valueDescriptor = Cog.Async.makeValueDescriptor(
      for: descriptor,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: lifetime,
      label: label
    )
  }
}
