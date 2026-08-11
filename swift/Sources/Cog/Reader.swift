/// The read capability inside one run of a selector.
///
/// This is the `c` in `Cog { c in ... }`. It is the read-side counterpart of
/// ``Writer``: a writer is the only way to change a source inside a turn, and a
/// reader is the only way to read inside a computation.
///
/// ```swift
/// let subtotal = Cog<Money> { c in
///   c.get(cart).items.reduce(.zero) { $0 + $1.price }
/// }
/// ```
///
/// Reading through `c.get` does two things at once, and the second is the point
/// (§2.4): it returns the value, and it records that this run depended on it.
/// Dependencies are exactly the cogs the last run read, so branches and early
/// returns are fine — an edge not read again is not an edge. Anything the
/// selector reads *around* the reader is invisible to Cog and will go stale.
///
/// A reader is valid only during the run it was handed to. Saving one and
/// reading through it later fails immediately rather than attaching
/// dependencies to a computation that is over.
///
/// `c.read` (an untracked peek, `M1-09c`) and `c.curr` (this cog's own previous
/// value, `M1-10`) join `get` here later.
@MainActor
public struct Reader<Value> {
  /// The context whose graph this run reads.
  private let cogs: Cogtext

  /// The node being computed — the consumer every read of this run links to,
  /// and, once `M1-10` lands, the holder of the `curr` value this run may fold
  /// into its result. That second use is why the reader is generic over the
  /// value its own cog produces rather than being one untyped read handle.
  private let node: DerivedCogNode<Value>

  /// Hands a run its reader. Only a node computing itself may make one.
  internal init(cogs: Cogtext, node: DerivedCogNode<Value>) {
    self.cogs = cogs
    self.node = node
  }

  /// Reads a source, and depends on it.
  ///
  /// - Parameter ref: The source to read.
  /// - Returns: The value the source holds in the latest completed turn —
  ///   never a value another turn has staged but not committed (§2.2).
  public func get<Read>(_ ref: ManualCog<Read>) -> Read {
    cogs.requireTracking(node)

    let producer = cogs.manualNode(for: ref)
    node.recordDependency(on: producer)
    return producer.currentValue
  }

  /// Reads another derived cog, and depends on it.
  ///
  /// Reading a derived cog that has not computed yet computes it, right here,
  /// as part of this run. That is what makes a graph of derived values lazy as
  /// a whole rather than one layer at a time: nothing downstream of an unread
  /// root runs until a read reaches it (§2.2).
  ///
  /// - Parameter ref: The derived cog to read.
  /// - Returns: Its value in this context.
  public func get<Read>(_ ref: Cog<Read>) -> Read {
    cogs.requireTracking(node)

    let producer = cogs.derivedNode(for: ref)
    node.recordDependency(on: producer)
    return producer.settledValue(in: cogs)
  }

  /// Reads a source exposed through `.readOnly`, and depends on it.
  ///
  /// This is how a selector reads state another file owns. §4's rule is that
  /// a source stays `fileprivate` and is published as a read-only projection,
  /// so without this overload a derived cog could only ever read state
  /// declared in its own file — which is the opposite of the intent.
  ///
  /// - Parameter ref: The read-only projection to read.
  /// - Returns: The value its source holds in the latest completed turn.
  public func get<Read>(_ ref: ReadOnlyCog<Read>) -> Read {
    get(ref.source)
  }
}
