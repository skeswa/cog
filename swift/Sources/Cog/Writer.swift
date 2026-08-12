/// The write capability for one accumulating turn.
///
/// A writer exists inside ``Cogtext/commit(_:_:)``. Its subscript reads staged
/// values and stages writes until the outer commit body returns. Application
/// code cannot construct one.
///
/// Do not save a writer in an escaping closure or `Task`. Reads and writes trap
/// after the commit body ends because the staged view no longer exists.
@MainActor
public struct Writer {
  private let cogs: Cogtext

  /// The turn this writer may act on.
  ///
  /// Held strongly so object identity cannot be reused while a writer exists.
  private let turnID: CogTurnID

  internal init(cogs: Cogtext, turnID: CogTurnID) {
    self.cogs = cogs
    self.turnID = turnID
  }

  /// Reads or stages one manual source in this turn.
  public subscript<Value>(_ valueReference: ManualCog<Value>) -> Value {
    get { cogs.writerRead(valueReference, turnID: turnID) }
    nonmutating set { cogs.writerStage(valueReference, value: newValue, turnID: turnID) }
  }
}

extension Cogtext {
  /// Starts or schedules one named, synchronous state transition.
  ///
  /// From idle, `body` starts a turn. A nested commit joins an accumulating
  /// turn. During a flush, it enters the FIFO queue as a later turn. That
  /// queued call returns immediately; the outer commit drains the queue before
  /// returning.
  ///
  /// The writer's changes cross the commit boundary together. Ops are
  /// `Cogtext` methods that wrap this primitive.
  ///
  /// Calling `commit` during a derived computation traps before `body` runs.
  /// The error names the active cog and attempted turn.
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history. By default,
  ///     this is the op method that called `commit`.
  ///   - body: The synchronous writes that make up the turn. The writer it
  ///     receives is valid only while that body is executing.
  public func commit(_ name: String = #function, _ body: @escaping (Writer) -> Void) {
    withTurn(name) { turn in
      body(Writer(cogs: self, turnID: turn.id))
    }
  }

  /// Reads through a writer after proving it belongs to the active turn.
  internal func writerRead<Value>(_ valueReference: ManualCog<Value>, turnID: CogTurnID) -> Value {
    requireWriterTurn(turnID, usage: .reading, target: valueReference)

    let state = manualState(for: valueReference)
    guard case .some(let pending) = state.pendingValue else {
      return state.currentValue
    }
    return pending
  }

  /// Stages a value after proving the writer belongs to the active turn.
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
