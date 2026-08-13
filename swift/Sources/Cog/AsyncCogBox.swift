/// A family of asynchronously derived values sharing one declaration.
///
/// A box owns one declaration descriptor and builds lightweight ``AsyncCog``
/// value references for its keys. Each descriptor-and-key pair has its own
/// phase, dependencies, generation, lifetime state, and work task in a
/// ``Cogtext``:
///
/// ```swift
/// let fetchedWeather = AsyncCogBox<Weather, ZipCode>(name: "weather.fetch") {
///   c, zip in
///   let service = c[weatherService]
///   return .run { try await service.weather(for: zip) }
/// }
/// ```
///
/// Building `box[key]` creates no state and allocates no new descriptor. Equal
/// keys produce the same declaration-and-key identity, while unequal keys are
/// independent even though they share selector code and policy. A context
/// creates a key's state only when that reference is first demanded; another
/// context creates separate state for the same key.
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

  /// Stable latest-projection identity shared by all keys and box copies.
  internal let latestDescriptor: DerivedCogDescriptor<Value?>

  /// Declares a keyed async derived value.
  ///
  /// This creates one async descriptor and one latest-projection descriptor,
  /// regardless of how many keys are later used. The synchronous selector runs
  /// separately whenever one key needs a new generation. Its tracked reads are
  /// dependencies of that key only; sibling keys neither invalidate nor
  /// replace one another unless the selector explicitly makes them share a
  /// dependency.
  ///
  /// Initial demand for a key publishes pending with no previous value. Under
  /// `.latest`, a reload cancels and supersedes only that key's prior task, and
  /// a stale completion cannot commit. By default, each unobserved key is
  /// released independently after grace and pending work is cancelled.
  ///
  /// - Parameters:
  ///   - policy: How new work for one key interacts with that key's in-flight
  ///     run. `.latest` is the first slice's default and only policy. Sibling
  ///     keys never replace one another's work.
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
    keepAlive: Bool = false,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ selector: @escaping @MainActor (Reader<CogPhase<Value>>, Key) -> Work<Value>
  ) {
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let descriptor = AsyncCogDescriptor(
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
      lifetime: CogStateLifetime(keepAlive: keepAlive),
      label: label
    )
    self.descriptor = descriptor
    self.latestDescriptor = AsyncCog.makeLatestDescriptor(
      for: descriptor,
      equals: nil,
      lifetime: CogStateLifetime(keepAlive: keepAlive),
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
      latestDescriptor: latestDescriptor,
      key: AnyHashable(key)
    )
  }

  /// A keyed projection that reads each key's last successful value.
  ///
  /// Subscripting this projection with a key names the same stable projection
  /// as `self[key].latest`; it does not create per-access descriptors. A key
  /// returns `nil` before its first success and retains its last success while
  /// later work is pending or failed. Read `self[key]` instead when loading or
  /// error details matter.
  ///
  /// Projection state follows the corresponding async key's lifetime. A
  /// latest-only consumer releases both states at one shared grace deadline.
  /// For `Equatable` values, an unchanged latest value stops the downstream
  /// wave independently for each key while full-phase turns remain visible.
  /// Accessing the property is inert; a read such as
  /// `cogs[forecast.latest[key]]` demands and tracks the same keyed async state
  /// as `cogs[forecast[key].latest]`.
  ///
  /// - Returns: A keyed facade over the box's one stable latest-projection
  ///   descriptor.
  public var latest: CogBox<Value?, Key> {
    CogBox(descriptor: latestDescriptor)
  }
}

extension AsyncCogBox where Value: Equatable {
  /// Declares keyed async values with equality-gated ``latest`` updates.
  ///
  /// Scheduling, cancellation, state identity, actor execution, and lifetime
  /// are identical to the unconstrained initializer. Equality affects only
  /// each key's optional latest projection: full-phase consumers still observe
  /// pending and success turns even when the successful value is unchanged.
  ///
  /// - Parameters:
  ///   - policy: How replacement work interacts with an in-flight run for the
  ///     same key. Only `.latest` is currently available.
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
    let label = CogLabel(name: name, fileID: fileID, line: line)
    let descriptor = AsyncCogDescriptor(
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
      lifetime: CogStateLifetime(keepAlive: keepAlive),
      label: label
    )
    self.descriptor = descriptor
    self.latestDescriptor = AsyncCog.makeLatestDescriptor(
      for: descriptor,
      equals: { oldValue, newValue in oldValue == newValue },
      lifetime: CogStateLifetime(keepAlive: keepAlive),
      label: label
    )
  }
}
