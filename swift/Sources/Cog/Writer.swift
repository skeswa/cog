/// The write capability for one accumulating turn.
///
/// A writer exists inside ``Cogs/turn(_:_:)``. Its subscript reads staged
/// values and stages writes until the outer turn body returns. Application
/// code cannot construct one.
///
/// All access is MainActor-isolated and names only ``ManualCog`` sources;
/// automatic cogs and read-only projections deliberately have no writer
/// subscript. A normal read sees the latest completed turn, but a writer read
/// sees this accumulating turn's most recently staged value so read-modify-write
/// operations compose correctly.
///
/// Do not save a writer in an escaping closure or `Task`. Reads and writes trap
/// after the turn body ends because the staged view no longer exists.
@MainActor
public struct Writer {
  /// The graph that owns the accumulating turn and source states.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let cogs: Cogs

  /// The turn this writer may act on.
  ///
  /// Held strongly so object identity cannot be reused while a writer exists.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let turnID: CogTurnID

  /// Reads or stages one manual source in this writer's turn.
  ///
  /// The getter returns the last value staged through this turn, or the latest
  /// completed value when the source has not been written yet. The setter
  /// replaces that staged value; only the final value reaches equality checks
  /// and the turn boundary. Reads and writes through an escaped writer trap
  /// in every build.
  ///
  /// - Parameter valueReference: The writable descriptor-and-key identity to
  ///   read or stage.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public subscript<Value>(_ valueReference: ManualCog<Value>) -> Value {
    get { cogs.writerRead(valueReference, turnID: turnID) }
    nonmutating set { cogs.writerStage(valueReference, value: newValue, turnID: turnID) }
  }
}

extension Cogs {
  /// Starts or schedules one named, synchronous state transition.
  ///
  /// From idle, `body` starts a turn. A nested turn joins an accumulating
  /// turn. During a flush, it enters the FIFO queue as a later turn. That
  /// queued call returns immediately; the outer turn drains the queue before
  /// returning.
  ///
  /// The writer's changes cross the turn boundary together. Ops are
  /// `Cogs` methods that wrap this primitive. Normal reads made before the
  /// boundary still see the prior completed snapshot; reactions, automatic
  /// settlement, Observation notices, and debug history run only as the turn
  /// flushes.
  ///
  /// Calling `turn` during an automatic computation traps before `body` runs.
  /// The error names the active cog and attempted turn. The method is
  /// MainActor-isolated through `Cogs`; `body` is synchronous even though
  /// it is escaping for queued-turn storage.
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history. The
  ///     defaulted ``CogOps/turn(_:_:)`` sugar passes the calling
  ///     op's `#function`.
  ///   - body: The synchronous writes that make up the turn. The writer it
  ///     receives is valid only while that body is executing.
  public func turn(named name: String, _ body: @escaping (Writer) -> Void) {
    withTurn(name) { turn in
      body(Writer(cogs: self, turnID: turn.id))
    }
  }

  /// Writes one value to one manual source in its own turn, without building a closure.
  ///
  /// This shadows ``CogOps/turn(_:to:name:)`` for a caller whose static type
  /// is `Cogs`, which is every application write. The protocol-extension
  /// spelling remains for `any CogOps` and for a mechanism's controller.
  ///
  /// The sugar used to reach the primitive through two escaping closures — one
  /// per layer — and `M9-01` measured both as heap allocations on every turn.
  /// Only a turn during a flush genuinely escapes, because it is stored and
  /// run after the current flush returns, so only that case still pays.
  ///
  /// - Parameters:
  ///   - valueReference: The state-owned source to update.
  ///   - value: The value to publish at the turn boundary.
  ///   - name: The turn name recorded for diagnostics and history.
  public func turn<Value>(
    _ valueReference: ManualCog<Value>,
    to value: Value,
    name: String = #function
  ) {
    requireOutsideAutomaticComputation(forTurnNamed: name)

    // Nothing between this test and the calls below can change the phase: the
    // context is MainActor-confined and neither step reaches user code.
    //
    // The queued path goes through `withTurn` rather than back through
    // `turn(named:)`. Reaching for the public primitive here would have been
    // the library calling its own op vocabulary from inside the implementation,
    // which `primitives-only-in-ops` exists to prevent and which Cog's own
    // linter caught. It is also less work: the queued body stages directly and
    // never builds a `Writer`.
    if case .flushing = turnPhase {
      withTurn(name) { turn in
        self.writerStage(valueReference, value: value, turnID: turn.id)
      }
      return
    }

    withNonEscapingTurn(name) { turn in
      writerStage(valueReference, value: value, turnID: turn.id)
    }
  }

  /// Reads the staged overlay after proving the writer belongs to the active turn.
  ///
  /// Validation precedes state lookup so an escaped writer cannot lazily create
  /// state outside its turn.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  internal func writerRead<Value>(_ valueReference: ManualCog<Value>, turnID: CogTurnID) -> Value {
    requireWriterTurn(turnID, usage: .reading, target: valueReference)

    return arenaCore.writerValue(for: valueReference)
  }

  /// Replaces a source's staged value and marks it touched once for this turn.
  ///
  /// Touching delegates deduplication to the turn, so repeated writes preserve
  /// the last staged value without duplicating turn-boundary work.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  internal func writerStage<Value>(
    _ valueReference: ManualCog<Value>,
    value: Value,
    turnID: CogTurnID
  ) {
    let turn = requireWriterTurn(turnID, usage: .writing, target: valueReference)

    arenaCore.writerStage(valueReference, value: value, in: turn)
    arenaCore.scheduleLifetimeReleaseIfUnobserved(for: valueReference, in: self)
  }

  /// The turn a writer may act on, or a trap if that turn is no longer open.
  ///
  /// A writer is valid while its ``CogTurnID`` matches the accumulating turn.
  ///
  /// The check runs in every build. A stale write would bypass settlement and
  /// notification; a stale read has no valid staged value to return.
  ///
  /// `fatalError` keeps the composed message under optimization, including
  /// `-Ounchecked`. `preconditionFailure` does not.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  @discardableResult
  internal func requireWriterTurn<Value>(
    _ turnID: CogTurnID,
    usage: WriterUsage,
    target valueReference: ManualCog<Value>
  ) -> CogTurn {
    guard case .accumulating(let turn) = turnPhase, turn.id == turnID else {
      // Composed inside the autoclosure, so a live write pays nothing to build
      // a message it never prints.
      fatalError(escapedWriterMessage(usage: usage, target: valueReference))
    }
    return turn
  }
}

/// Which half of the writer subscript ran into an ended turn.
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal enum WriterUsage {
  case reading
  case writing

  /// What the caller was doing, as the message says it.
  var attempt: String {
    switch self {
    case .reading: return "reading"
    case .writing: return "writing to"
    }
  }
}

/// What Cog says when a writer is used after its turn ended.
///
/// Names the escaped writer's target and tells the caller to open a new turn.
@MainActor
private func escapedWriterMessage<Value>(
  usage: WriterUsage,
  target valueReference: ManualCog<Value>
) -> String {
  """
  This Cog writer outlived the turn that created it, so \(usage.attempt) \
  \(escapedWriterTargetName(valueReference)) through it is not part of any turn. A writer \
  is valid only while the body of the turn that made it is still running, so \
  never stash one in a variable, capture it in an escaping closure, or carry \
  it into a Task. To write state now, call turn again and use the writer it \
  passes to your body.
  """
}

/// The source the escaped writer reached for, as a person would name it.
@MainActor
private func escapedWriterTargetName<Value>(_ valueReference: ManualCog<Value>) -> String {
  guard let key = valueReference.key else { return "\(valueReference.descriptor.label)" }
  return "\(valueReference.descriptor.label)[\(key.erased.base)]"
}
