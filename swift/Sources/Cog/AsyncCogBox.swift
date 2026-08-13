/// An async derived value produced separately for every key.
///
/// A box owns one declaration descriptor and builds lightweight ``AsyncCog``
/// value references for its keys. Each descriptor-and-key pair has its own
/// phase, dependencies, generation, and work task in a ``Cogtext``:
///
/// ```swift
/// let fetchedWeather = AsyncCogBox<Weather, ZipCode>(name: "weather.fetch") {
///   c, zip in
///   let service = c[weatherService]
///   return .run { try await service.weather(for: zip) }
/// }
/// ```
///
/// Building `box[key]` creates no state and allocates no new descriptor. The
/// context creates that key's state when the value reference is first read.
@MainActor
public struct AsyncCogBox<Value, Key: Hashable> {
  /// The one declaration behind every key of this box.
  internal let descriptor: AsyncCogDescriptor<Value>

  /// The one latest-value declaration behind every key of this box.
  internal let latestDescriptor: DerivedCogDescriptor<Value?>

  /// Declares a keyed async derived value.
  ///
  /// This allocates one descriptor. The synchronous selector runs separately
  /// for each key when that key first needs work, and returns the work that
  /// produces the key's value.
  ///
  /// - Parameters:
  ///   - policy: How new work for one key interacts with that key's in-flight
  ///     run. `.latest` is the first slice's default and only policy. Sibling
  ///     keys never replace one another's work.
  ///   - keepAlive: Whether every key has app lifetime instead of the
  ///     async-derived `whileObserved` default.
  ///   - name: What Cog should call this declaration in turns, diagnostics,
  ///     and task tools. A rendered keyed name includes the key.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
  ///   - selector: Synchronous dependency selection for one key that returns
  ///     its async work.
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
  /// phases independently while sharing this box's declaration descriptor.
  public subscript(key: Key) -> AsyncCog<Value> {
    AsyncCog(
      descriptor: descriptor,
      latestDescriptor: latestDescriptor,
      key: AnyHashable(key)
    )
  }
}

extension AsyncCogBox where Value: Equatable {
  /// Declares a keyed async value whose equal latest successes stop downstream work.
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
