/// The write capability for one accumulating turn.
///
/// A writer exists inside ``Cogs/commit(_:_:)``. Its subscript reads staged
/// values and stages writes until the outer commit body returns. Application
/// code cannot construct one.
///
/// All access is MainActor-isolated and names only ``ManualCog`` sources;
/// derived cogs and read-only projections deliberately have no writer
/// subscript. A normal read sees the latest completed turn, but a writer read
/// sees this accumulating turn's most recently staged value so read-modify-write
/// operations compose correctly.
///
/// Do not save a writer in an escaping closure or `Task`. Reads and writes trap
/// after the commit body ends because the staged view no longer exists.
@MainActor
public struct Writer {
  /// The graph that owns the accumulating turn and source states.
  private let cogs: Cogs

  /// The turn this writer may act on.
  ///
  /// Held strongly so object identity cannot be reused while a writer exists.
  private let turnID: CogTurnID

  /// Creates the capability for one exact accumulating turn.
  ///
  /// The context and identity are deliberately paired: validating object
  /// identity on every access prevents an escaped writer from joining a later
  /// turn that happens to run in the same context.
  ///
  /// - Parameters:
  ///   - cogs: The graph that owns the active turn and manual state.
  ///   - turnID: The retained identity that must still match that active turn.
  internal init(cogs: Cogs, turnID: CogTurnID) {
    self.cogs = cogs
    self.turnID = turnID
  }

  /// Reads or stages one manual source in this writer's turn.
  ///
  /// The getter returns the last value staged through this turn, or the latest
  /// completed value when the source has not been written yet. The setter
  /// replaces that staged value; only the final value reaches equality checks
  /// and the commit boundary. Reads and writes through an escaped writer trap
  /// in every build.
  ///
  /// - Parameter valueReference: The writable descriptor-and-key identity to
  ///   read or stage.
  public subscript<Value>(_ valueReference: ManualCog<Value>) -> Value {
    get { cogs.writerRead(valueReference, turnID: turnID) }
    nonmutating set { cogs.writerStage(valueReference, value: newValue, turnID: turnID) }
  }
}

extension Cogs {
  /// Starts or schedules one named, synchronous state transition.
  ///
  /// From idle, `body` starts a turn. A nested commit joins an accumulating
  /// turn. During a flush, it enters the FIFO queue as a later turn. That
  /// queued call returns immediately; the outer commit drains the queue before
  /// returning.
  ///
  /// The writer's changes cross the commit boundary together. Ops are
  /// `Cogs` methods that wrap this primitive. Normal reads made before the
  /// boundary still see the prior completed snapshot; reactions, derived
  /// settlement, Observation notices, and debug history run only as the turn
  /// flushes.
  ///
  /// Calling `commit` during a derived computation traps before `body` runs.
  /// The error names the active cog and attempted turn. The method is
  /// MainActor-isolated through `Cogs`; `body` is synchronous even though
  /// it is escaping for queued-turn storage.
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history. The
  ///     defaulted ``CogOperating/commit(_:_:)`` sugar passes the calling
  ///     op's `#function`.
  ///   - body: The synchronous writes that make up the turn. The writer it
  ///     receives is valid only while that body is executing.
  public func commit(named name: String, _ body: @escaping (Writer) -> Void) {
    withTurn(name) { turn in
      body(Writer(cogs: self, turnID: turn.id))
    }
  }

  /// Reads the staged overlay after proving the writer belongs to the active turn.
  ///
  /// Validation precedes state lookup so an escaped writer cannot lazily create
  /// state outside its turn.
  internal func writerRead<Value>(_ valueReference: ManualCog<Value>, turnID: CogTurnID) -> Value {
    requireWriterTurn(turnID, usage: .reading, target: valueReference)

    let state = manualState(for: valueReference)
    guard case .some(let pending) = state.pendingValue else {
      return state.currentValue
    }
    return pending
  }

  /// Replaces a source's staged value and marks it touched once for this turn.
  ///
  /// Touching delegates deduplication to the turn, so repeated writes preserve
  /// the last staged value without duplicating commit-boundary work.
  internal func writerStage<Value>(
    _ valueReference: ManualCog<Value>,
    value: Value,
    turnID: CogTurnID
  ) {
    let turn = requireWriterTurn(turnID, usage: .writing, target: valueReference)

    let state = manualState(for: valueReference)
    state.pendingValue = .some(value)
    turn.touch(state)
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
  @discardableResult
  private func requireWriterTurn<Value>(
    _ turnID: CogTurnID,
    usage: WriterUsage,
    target valueReference: ManualCog<Value>
  ) -> CogTurn {
    guard case .accumulating(let turn) = turnPhase, turn.id === turnID else {
      // Composed inside the autoclosure, so a live write pays nothing to build
      // a message it never prints.
      fatalError(escapedWriterMessage(usage: usage, target: valueReference))
    }
    return turn
  }
}

/// Which half of the writer subscript ran into an ended turn.
private enum WriterUsage {
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

/// What Cog says when a writer is used after its commit ended.
///
/// Names the escaped writer's target and tells the caller to open a new commit.
@MainActor
private func escapedWriterMessage<Value>(
  usage: WriterUsage,
  target valueReference: ManualCog<Value>
) -> String {
  """
  This Cog writer outlived the commit that created it, so \(usage.attempt) \
  \(escapedWriterTargetName(valueReference)) through it is not part of any turn. A writer \
  is valid only while the body of the commit that made it is still running, so \
  never stash one in a variable, capture it in an escaping closure, or carry \
  it into a Task. To write state now, call commit again and use the writer it \
  passes to your body.
  """
}

/// The source the escaped writer reached for, as a person would name it.
@MainActor
private func escapedWriterTargetName<Value>(_ valueReference: ManualCog<Value>) -> String {
  guard let key = valueReference.key else { return "\(valueReference.descriptor.label)" }
  return "\(valueReference.descriptor.label)[\(key.base)]"
}
