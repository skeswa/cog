/// The write capability for one accumulating turn.
///
/// A writer exists only inside ``Cogtext/commit(_:_:)``. Its subscripts
/// are the only way to change a manual source: reads prefer what this turn has
/// already staged, and writes stay pending until the outer commit body exits.
/// Application code cannot construct a writer because its initializer and
/// turn identity are internal to Cog.
///
/// A writer is also valid only *while* that commit body is running. Stashing
/// one in a variable, an escaping closure, or a `Task` and using it later is a
/// programmer error, not a supported way to write outside a turn, and Cog traps
/// on it in every build configuration (§3.2). The trap covers reads as much as
/// writes: a writer read means "what this turn has staged," which is a question
/// with no answer once the turn is over, and silently degrading it to a normal
/// read would hand back a plausible wrong value.
@MainActor
public struct Writer {
  private let cogs: Cogtext

  /// The turn this writer may act on.
  ///
  /// Strongly held on purpose. The check downstream is object identity, so the
  /// token has to stay alive for exactly as long as some writer could still
  /// name it; a freed token could otherwise let a later turn's allocation land
  /// on the same address and make an escaped writer look current.
  private let turnID: CogTurnID

  internal init(cogs: Cogtext, turnID: CogTurnID) {
    self.cogs = cogs
    self.turnID = turnID
  }

  /// Reads or stages one manual source in this turn.
  public subscript<Value>(_ ref: ManualCog<Value>) -> Value {
    get { cogs.writerRead(ref, turnID: turnID) }
    nonmutating set { cogs.writerStage(ref, value: newValue, turnID: turnID) }
  }
}

extension Cogtext {
  /// Starts or schedules one named, synchronous state transition.
  ///
  /// From idle, `body` starts a new outer turn. Inside an accumulating turn it
  /// joins that turn immediately. During a flush it waits in the context's
  /// FIFO queue and runs as a later turn, after the active turn is completely
  /// settled. Queuing is non-reentrant: this particular call returns before a
  /// queued body runs, while the active outer `commit` drains all arrivals
  /// before *its* call returns.
  ///
  /// Writes made through `body`'s ``Writer`` remain staged until the outer
  /// accumulating body returns, then cross the commit boundary together. Ops
  /// are ordinary `Cogtext` methods that wrap this primitive.
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
  internal func writerRead<Value>(_ ref: ManualCog<Value>, turnID: CogTurnID) -> Value {
    requireWriterTurn(turnID, usage: .reading, target: ref)

    let node = manualNode(for: ref)
    guard case .some(let pending) = node.pendingValue else {
      return node.currentValue
    }
    return pending
  }

  /// Stages a value after proving the writer belongs to the active turn.
  internal func writerStage<Value>(
    _ ref: ManualCog<Value>,
    value: Value,
    turnID: CogTurnID
  ) {
    let turn = requireWriterTurn(turnID, usage: .writing, target: ref)

    let node = manualNode(for: ref)
    node.pendingValue = .some(value)
    turn.touch(node)
  }

  /// The turn a writer may act on, or a trap if that turn is no longer open.
  ///
  /// The token is unforgeable (``CogTurnID``), so this is the whole capability
  /// check: a writer is live exactly while its own token is the context's
  /// accumulating turn. Everything else is an escaped writer — the context is
  /// idle, or flushing this very turn, or already accumulating a later one —
  /// and all three mean the same thing to the caller, that the commit which
  /// handed out this writer has ended.
  ///
  /// Failing is a trap, not an `assert`, because the check has to hold in
  /// shipping builds too. There is no correct behavior to fall back on: a stale
  /// write would mutate state outside every turn, so nothing would settle or
  /// notify against it, and a stale read would answer a question about a turn
  /// that is over. Both are silent wrong state, which costs more than a crash.
  ///
  /// It is `fatalError` rather than `preconditionFailure` specifically so the
  /// message survives optimization. An optimized `preconditionFailure` lowers
  /// to `Builtin.condfail_message`, which wants a static string; hand it a
  /// composed one and the release binary prints raw bytes where the sentence
  /// should be. `fatalError` always goes through the runtime's reporting path,
  /// so the same words reach a release crash report as a debug console — and
  /// this message is worth more than most, because the file and line the trap
  /// reports are Cog's, not the caller's. Naming their cog is the only locating
  /// information they get. Being un-strippable under `-Ounchecked` is the right
  /// posture for a capability check besides.
  @discardableResult
  private func requireWriterTurn<Value>(
    _ turnID: CogTurnID,
    usage: WriterUsage,
    target ref: ManualCog<Value>
  ) -> CogTurn {
    guard case .accumulating(let turn) = turnPhase, turn.id === turnID else {
      // Composed inside the autoclosure, so a live write pays nothing to build
      // a message it never prints.
      fatalError(escapedWriterMessage(usage: usage, target: ref))
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
/// The message has one job beyond stopping the program: telling whoever reads
/// the crash the two things they cannot see from the trap's own file and line,
/// which point into Cog rather than into their code. Those are what went wrong
/// — the writer outlived its commit — and what to do instead, which is to call
/// `commit` again rather than to look for a way to write without a turn.
@MainActor
private func escapedWriterMessage<Value>(
  usage: WriterUsage,
  target ref: ManualCog<Value>
) -> String {
  """
  This Cog writer outlived the commit that created it, so \(usage.attempt) \
  \(escapedWriterTargetName(ref)) through it is not part of any turn. A writer \
  is valid only while the body of the commit that made it is still running, so \
  never stash one in a variable, capture it in an escaping closure, or carry \
  it into a Task. To write state now, call commit again and use the writer it \
  passes to your body.
  """
}

/// The source the escaped writer reached for, as a person would name it.
@MainActor
private func escapedWriterTargetName<Value>(_ ref: ManualCog<Value>) -> String {
  guard let key = ref.key else { return "\(ref.descriptor.label)" }
  return "\(ref.descriptor.label)[\(key.base)]"
}
