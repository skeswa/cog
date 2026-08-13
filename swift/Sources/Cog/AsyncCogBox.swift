/// A family of asynchronously derived values sharing one declaration.
///
/// A box owns one declaration descriptor and builds lightweight ``AsyncCog``
/// value references for its keys. Each descriptor-and-key pair has its own
/// phase, dependencies, generation, lifetime state, and work task in a
/// ``Cogtext``:
///
/// ```swift
/// let fetchedWeather = AsyncCogBox<Weather?, ZipCode>(name: "weather.fetch") {
///   c, zip in
///   let service = c[weatherService]
///   return .run { try await service.weather(for: zip) }
/// }
/// ```
///
/// Value reads of a key are total: `c[fetchedWeather[zip]]` returns the last
/// accepted success for that key, resting on the declaration's default — for
/// an omitted default on an optional value, `nil` — until one exists. Each
/// key's full request lifecycle reads through the `phase` lens,
/// `c.phase[fetchedWeather[zip]]`.
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
public struct AsyncCogBox<Value, Key: Hashable> {
  /// Stable async-declaration identity shared by all keys and box copies.
  internal let descriptor: AsyncCogDescriptor<Value>

  /// Stable value-projection identity shared by all keys and box copies.
  internal let valueDescriptor: DerivedCogDescriptor<Value>

  /// Declares a keyed async derived value with an explicit resting default.
  ///
  /// This creates one async descriptor and one value-projection descriptor,
  /// regardless of how many keys are later used. The synchronous selector runs
  /// separately whenever one key needs a new generation. Its tracked reads are
  /// dependencies of that key only; sibling keys neither invalidate nor
  /// replace one another unless the selector explicitly makes them share a
  /// dependency.
  ///
  /// Initial demand for a key publishes pending with no previous value; that
  /// key's value read rests on `default` until its first success. Under
  /// `.latest`, a reload cancels and supersedes only that key's prior task, and
  /// a stale completion cannot commit. By default, each unobserved key is
  /// released independently after grace and pending work is cancelled.
  ///
  /// - Parameters:
  ///   - policy: How new work for one key interacts with that key's in-flight
  ///     run. `.latest` is the first slice's default and only policy. Sibling
  ///     keys never replace one another's work.
  ///   - default: The honest resting value every key's value read returns
  ///     before that key's first success. Choose one that renders truthfully
  ///     while work is in flight; when no such value exists, make `Value`
  ///     optional and omit this argument instead.
  ///   - keepAlive: Pass `true` to retain every demanded key until the context
  ///     ends. The default applies `whileObserved` grace independently to each
  ///     key.
  ///   - name: What Cog should call this declaration in turns, diagnostics,
  ///     and task tools. A rendered keyed name includes the key.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection for one key, returning a
  ///     fresh async operation for that key's next generation.
  public init(
    _ policy: LatestPolicy = .latest,
    default defaultValue: Value,
    keepAlive: Bool = false,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogPhase<Value>>, Key) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let lifetime = CogStateLifetime(keepAlive: keepAlive)
    let descriptor = Self.makeDescriptor(
      policy: policy,
      lifetime: lifetime,
      label: label,
      selector: selector
    )
    self.descriptor = descriptor
    self.valueDescriptor = AsyncCog.makeValueDescriptor(
      for: descriptor,
      default: defaultValue,
      equals: nil,
      lifetime: lifetime,
      label: label
    )
  }

  /// The value reference naming this box's async value for one key.
  ///
  /// Equal keys name the same state. Different keys fetch and advance their
  /// phases independently while sharing this box's declaration descriptors.
  /// Subscripting is inert: the returned reference creates state and starts
  /// work only when a context reads, peeks, or refreshes it.
  ///
  /// - Parameter key: The hashable value forming the state identity together
  ///   with this box's descriptor.
  /// - Returns: A lightweight async value reference for that identity.
  public subscript(key: Key) -> AsyncCog<Value> {
    AsyncCog(
      descriptor: descriptor,
      valueDescriptor: valueDescriptor,
      key: AnyHashable(key)
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
    policy: LatestPolicy,
    lifetime: CogStateLifetime,
    label: CogLabel,
    selector: @escaping @MainActor (Reader<CogPhase<Value>>, Key) -> Work<Value>
  ) -> AsyncCogDescriptor<Value> {
    AsyncCogDescriptor(
      policy: policy,
      selector: { c, erasedKey in
        guard let key = erasedKey as? Key else {
          fatalError(
            """
            A state of \(label) was asked to make work for \
            \(String(describing: erasedKey)), which is not a \(Key.self). Only this \
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

extension AsyncCogBox where Value: Equatable {
  /// Declares keyed async values with equality-gated value reads and an
  /// explicit resting default.
  ///
  /// Scheduling, cancellation, state identity, actor execution, and lifetime
  /// are identical to the unconstrained initializer. Equality affects only
  /// each key's value projection: `phase` consumers still observe pending and
  /// success turns even when the successful value is unchanged.
  ///
  /// - Parameters:
  ///   - policy: How replacement work interacts with an in-flight run for the
  ///     same key. Only `.latest` is currently available.
  ///   - default: The honest resting value every key returns before its first
  ///     success.
  ///   - keepAlive: Whether demanded keys remain until the context ends instead
  ///     of following independent `whileObserved` grace.
  ///   - name: A stable declaration label; rendered keyed labels include the key.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection returning one operation for
  ///     the requested key and generation.
  public init(
    _ policy: LatestPolicy = .latest,
    default defaultValue: Value,
    keepAlive: Bool = false,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogPhase<Value>>, Key) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let lifetime = CogStateLifetime(keepAlive: keepAlive)
    let descriptor = Self.makeDescriptor(
      policy: policy,
      lifetime: lifetime,
      label: label,
      selector: selector
    )
    self.descriptor = descriptor
    self.valueDescriptor = AsyncCog.makeValueDescriptor(
      for: descriptor,
      default: defaultValue,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: lifetime,
      label: label
    )
  }
}

extension AsyncCogBox where Value: CogDefaultable {
  /// Declares keyed async values resting on `Value`'s own default.
  ///
  /// Identical to the explicit-`default:` initializer except that the resting
  /// value comes from ``CogDefaultable/cogDefault`` — for an optional value,
  /// `nil`. Every key rests on the same default until its own first success.
  ///
  /// - Parameters:
  ///   - policy: How replacement work interacts with an in-flight run for the
  ///     same key.
  ///   - keepAlive: Whether demanded keys remain until the context ends instead
  ///     of following independent `whileObserved` grace.
  ///   - name: A stable declaration label; rendered keyed labels include the key.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection returning one operation for
  ///     the requested key and generation.
  public init(
    _ policy: LatestPolicy = .latest,
    keepAlive: Bool = false,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogPhase<Value>>, Key) -> Work<Value>
  ) {
    self.init(
      policy,
      default: Value.cogDefault,
      keepAlive: keepAlive,
      name: name,
      fileID: fileID,
      line: line,
      selector
    )
  }
}

extension AsyncCogBox where Value: CogDefaultable & Equatable {
  /// Declares keyed async values resting on `Value`'s own default, with
  /// equality-gated value reads.
  ///
  /// The most common keyed spelling for optional `Equatable` values:
  /// `AsyncCogBox<Weather?, ZipCode> { ... }` rests every key at `nil` and
  /// keeps value consumers quiet across equal-success reloads.
  ///
  /// - Parameters:
  ///   - policy: How replacement work interacts with an in-flight run for the
  ///     same key.
  ///   - keepAlive: Whether demanded keys remain until the context ends instead
  ///     of following independent `whileObserved` grace.
  ///   - name: A stable declaration label; rendered keyed labels include the key.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: MainActor dependency selection returning one operation for
  ///     the requested key and generation.
  public init(
    _ policy: LatestPolicy = .latest,
    keepAlive: Bool = false,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogPhase<Value>>, Key) -> Work<Value>
  ) {
    self.init(
      policy,
      default: Value.cogDefault,
      keepAlive: keepAlive,
      name: name,
      fileID: fileID,
      line: line,
      selector
    )
  }
}

extension AsyncCogBox {
  /// Unavailable: a keyed async declaration always has a resting value.
  ///
  /// This overload exists only to turn the missing-default mistake into a
  /// diagnostic that names both ways out, instead of an opaque
  /// no-matching-initializer error. It is chosen only when no available
  /// initializer applies — a non-`CogDefaultable` `Value` with no `default:`
  /// argument.
  @available(
    *, unavailable,
    message: """
      an async cog needs a resting value: pass `default:`, or make Value \
      Optional so it rests at nil
      """
  )
  public init(
    _ policy: LatestPolicy = .latest,
    keepAlive: Bool = false,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogPhase<Value>>, Key) -> Work<Value>
  ) {
    fatalError("unavailable")
  }
}
