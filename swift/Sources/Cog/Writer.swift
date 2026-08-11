/// The write capability for one accumulating turn.
///
/// A writer exists only inside ``Cogtext/commit(_:_:)``. Its subscripts
/// are the only way to change a manual source: reads prefer what this turn has
/// already staged, and writes stay pending until the outer commit body exits.
/// Application code cannot construct a writer because its initializer and
/// turn identity are internal to Cog.
@MainActor
public struct Writer {
  private let cogs: Cogtext
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
  /// Runs one named, synchronous state transition.
  ///
  /// Writes made through `body`'s ``Writer`` remain staged until the body
  /// returns. The outer boundary then commits them together before this method
  /// returns. Ops are ordinary `Cogtext` methods that wrap this primitive.
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history. By default,
  ///     this is the op method that called `commit`.
  ///   - body: The synchronous writes that make up the turn.
  public func commit(_ name: String = #function, _ body: (Writer) -> Void) {
    withTurn(name) { turn in
      body(Writer(cogs: self, turnID: turn.id))
    }
  }

  /// Reads through a writer after proving it belongs to the active turn.
  internal func writerRead<Value>(_ ref: ManualCog<Value>, turnID: CogTurnID) -> Value {
    let node = writableNode(for: ref, turnID: turnID)
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
    let (turn, node) = writableTurnAndNode(for: ref, turnID: turnID)
    node.pendingValue = .some(value)
    turn.touch(node)
  }

  private func writableNode<Value>(
    for ref: ManualCog<Value>,
    turnID: CogTurnID
  ) -> ManualCogNode<Value> {
    writableTurnAndNode(for: ref, turnID: turnID).1
  }

  private func writableTurnAndNode<Value>(
    for ref: ManualCog<Value>,
    turnID: CogTurnID
  ) -> (CogTurn, ManualCogNode<Value>) {
    guard case .accumulating(let turn) = turnPhase, turn.id === turnID else {
      preconditionFailure("A Cog writer is valid only inside the commit that created it.")
    }
    return (turn, manualNode(for: ref))
  }
}
