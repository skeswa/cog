/// A value produced by synchronous dependency selection followed by async work.
///
/// The selector runs on the MainActor and reads dependencies through its
/// ``Reader``. It returns ``Work`` so dependency capture ends before any
/// suspension. The first read starts the work and returns
/// ``CogPhase/pending(previous:)`` with no previous value.
@MainActor
public struct AsyncCog<Value> {
  /// The declaration this value reference names.
  internal let descriptor: AsyncCogDescriptor<Value>

  /// The one derived declaration behind ``latest``.
  internal let latestDescriptor: DerivedCogDescriptor<Value?>

  /// The keyed state this reference names, or `nil` for a keyless declaration.
  internal let key: AnyHashable?

  /// Declares an async derived value.
  ///
  /// - Parameters:
  ///   - policy: How new work interacts with an in-flight run. `.latest` is
  ///     the first slice's default and only policy.
  ///   - keepAlive: Whether this declaration has app lifetime instead of the
  ///     async-derived `whileObserved` default.
  ///   - selector: Synchronous dependency selection that returns async work.
  ///   - name: What Cog should call this cog in turns, diagnostics, and task tools.
  ///   - fileID: The declaration's file. Leave this at its default.
  ///   - line: The declaration's line. Leave this at its default.
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

  /// Builds a keyed reference without allocating another descriptor.
  internal init(
    descriptor: AsyncCogDescriptor<Value>,
    latestDescriptor: DerivedCogDescriptor<Value?>,
    key: AnyHashable?
  ) {
    self.descriptor = descriptor
    self.latestDescriptor = latestDescriptor
    self.key = key
  }
  /// A value reference that reads only the last successful value.
  ///
  /// Pending and failure phases retain their previous success. For equatable
  /// values, an unchanged latest value stops the downstream wave.
  public var latest: Cog<Value?> {
    Cog(descriptor: latestDescriptor, key: key)
  }

  /// Builds the stable projection descriptor shared by copies of this reference.
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
  /// Declares an async value whose equal latest successes stop downstream work.
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
