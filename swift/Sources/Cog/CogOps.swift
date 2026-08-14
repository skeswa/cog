/// The shared operation surface of the app runtime and a mechanism's
/// controller.
///
/// An op is an ordinary method written once in an `extension CogOps` and
/// callable on both capabilities: application code and views call it on the
/// retained `Cogs`, while a mechanism calls it on the controller its `operate`
/// received. One definition therefore serves every legitimate write site
/// without handing mechanisms the raw runtime (§3.2, §6.2).
///
/// ```swift
/// extension CogOps {
///   func selectCurrentLocation(_ zip: ZipCode) {
///     commit(currentZipSourceCog, to: zip)
///   }
/// }
/// ```
///
/// The protocol carries exactly the op primitives — `commit`, non-tracking
/// `peek`, and async `refresh` — and nothing that registers reactions or
/// exposes storage. Conformances outside Cog are unsupported: the two
/// capabilities are ``Cogs`` and ``MechanismController``, and ops written
/// against this protocol are what keeps them interchangeable.
@MainActor
public protocol CogOps {
  /// Opens one named turn and runs `body` against its staged writes.
  ///
  /// This is the primitive beneath every op. Call the defaulted
  /// ``commit(_:_:)`` sugar instead so the turn inherits the op's `#function`
  /// name; pass an explicit name only when the op's spelling is not the right
  /// history entry. A mechanism's controller composes its mechanism name onto
  /// the turn name, so history attributes the write to the mechanism that
  /// asked for it.
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history.
  ///   - body: The synchronous writes that make up the turn. The writer it
  ///     receives is valid only while that body is executing.
  func commit(named name: String, _ body: @escaping (Writer) -> Void)

  /// Reads a source's current value without creating a dependency edge.
  ///
  /// See ``Cogs/peek(_:)-swift.method`` for the settlement and lifetime
  /// contract; both conformances share it exactly.
  func peek<Value>(_ valueReference: ManualCog<Value>) -> Value

  /// Reads a derived cog's settled value without creating a dependency edge.
  func peek<Value>(_ valueReference: Cog<Value>) -> Value

  /// Reads an async cog's current value without creating a dependency edge.
  func peek<Value>(_ valueReference: AsyncCog<Value>) -> Value

  /// Reads a source's read-only projection without creating a dependency
  /// edge.
  func peek<Value>(_ valueReference: CogProjection<Value>) -> Value

  /// Demands one fresh generation of an async value.
  ///
  /// See ``Cogs/refresh(_:)`` for the demand, grace, and handle contract.
  @discardableResult
  func refresh<Value>(_ valueReference: AsyncCog<Value>) -> CogRefresh<Value>
}

extension CogOps {
  /// Opens one turn named after the calling op and stages `body`'s writes.
  ///
  /// `commit` is the only write entry point. The writer overload groups
  /// related writes into one atomic turn; `#function` names the turn after
  /// the op that called it without extra code. Nested commits during the
  /// accumulating phase join the current turn; a commit requested while a
  /// turn is flushing waits in the FIFO queue as a later turn (§3.2).
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history. By
  ///     default, this is the op method that called `commit`.
  ///   - body: The synchronous writes that make up the turn. The writer it
  ///     receives is valid only while that body is executing.
  public func commit(_ name: String = #function, _ body: @escaping (Writer) -> Void) {
    commit(named: name, body)
  }

  /// Commits one value to one manual source.
  ///
  /// This is the compact form for the common single-write operation. It keeps
  /// the writer form as Cog's sole multi-write boundary while avoiding a
  /// one-line writer closure at every domain setter.
  ///
  /// - Parameters:
  ///   - valueReference: The state-owned source to update.
  ///   - value: The value to publish at the commit boundary.
  ///   - name: The turn name recorded for diagnostics and history.
  public func commit<Value>(
    _ valueReference: ManualCog<Value>,
    to value: Value,
    name: String = #function
  ) {
    commit(named: name) { writer in
      writer[valueReference] = value
    }
  }
}

/// `Cogs` is the application-side op capability.
///
/// The requirements are implemented where each primitive lives: the commit
/// boundary beside ``Writer``, the peeks beside state storage, and refresh
/// beside async demand.
extension Cogs: CogOps {}
