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
    self.init(
      descriptor: AsyncCogDescriptor(
        policy: policy,
        selector: { c, _ in selector(c) },
        lifetime: CogStateLifetime(keepAlive: keepAlive),
        label: CogLabel(name: name, fileID: fileID, line: line)
      ),
      key: nil
    )
  }

  /// Builds a keyed reference without allocating another descriptor.
  internal init(descriptor: AsyncCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
  }

  /// Builds a keyed reference solely for the task-name testing seam.
  ///
  /// `AsyncCogBox` owns the eventual public keyed API. Until it arrives, this
  /// package-only constructor lets `CogTesting` prove that internal task names
  /// include a descriptor's key without publishing an early API shape.
  package func valueReferenceForTaskNameDiagnostic<Key: Hashable>(
    _ key: Key
  ) -> AsyncCog<Value> {
    AsyncCog(descriptor: descriptor, key: AnyHashable(key))
  }
}
