/// How one ``CogValues`` iterator keeps changed values its reader has not consumed.
///
/// Buffering never blocks a synchronous graph turn. The default
/// ``newest(_:)`` policy bounds memory and favors the latest settled state for
/// UI consumers that fall behind.
public nonisolated enum CogValuesBuffering: Sendable, Equatable {
  /// Keep up to `limit` undelivered values, discarding the oldest on overflow.
  ///
  /// A limit must be greater than zero. ``Cogs/values(of:buffering:)-(Cog<Value>,_)``
  /// defaults to `.newest(1)`, so a paused reader resumes with the latest
  /// settled value without making intervening commits wait.
  case newest(Int)

  /// Keep the first `limit` undelivered values, discarding newer overflow.
  ///
  /// A limit must be greater than zero. This policy preserves the earliest
  /// unseen transitions for consumers that prefer ordered backlog over the
  /// newest state, while commits remain non-blocking when that backlog is full.
  case oldest(Int)

  /// Creates the standard-library stream storage for this public policy.
  ///
  /// Policy validation happens when a subscription iterator is created, before
  /// that iterator registers with the graph or settles any state.
  internal func makeStream<Value>(of: Value.Type) -> (
    stream: AsyncStream<Value>, continuation: AsyncStream<Value>.Continuation
  ) {
    switch self {
    case .newest(let limit):
      guard limit > 0 else {
        fatalError("CogValuesBuffering.newest requires a limit greater than zero.")
      }
      return AsyncStream.makeStream(
        of: Value.self,
        bufferingPolicy: .bufferingNewest(limit)
      )
    case .oldest(let limit):
      guard limit > 0 else {
        fatalError("CogValuesBuffering.oldest requires a limit greater than zero.")
      }
      return AsyncStream.makeStream(
        of: Value.self,
        bufferingPolicy: .bufferingOldest(limit)
      )
    }
  }
}

/// A current-value-first asynchronous subscription to one Cog value.
///
/// Create this sequence with ``Cogs/values(of:)-(Cog<Value>)`` or its manual
/// and async overloads. Creating an iterator establishes an independent graph
/// subscription, settles a cold value synchronously, and places that settled
/// value first. Later changed values are offered without making a graph turn
/// wait for the asynchronous consumer.
///
/// The sequence and its iterator are MainActor-isolated because Cog values may
/// deliberately be non-`Sendable`. Each iterator is a separate subscription;
/// do not drive one iterator concurrently from multiple tasks.
@MainActor
public struct CogValues<Value>: @MainActor AsyncSequence {
  /// The graph value emitted by this sequence.
  public typealias Element = Value

  /// Cog value subscriptions end normally and never throw.
  public typealias Failure = Never

  /// Creates one independently buffered graph subscription.
  private let makeIteratorBody: @MainActor () -> Iterator

  /// Builds a lazy sequence around one tracked graph read.
  ///
  /// No state settles until an iterator is requested. Capturing the context
  /// weakly lets a retained but never-iterated sequence outlive an isolated
  /// test runtime without keeping that runtime alive.
  internal init(
    cogs: Cogs,
    label: CogLabel,
    buffering: CogValuesBuffering,
    read: @escaping @MainActor (ReactionReader) -> Value
  ) {
    makeIteratorBody = { [weak cogs] in
      guard let cogs else { return Iterator.finished() }

      let (stream, continuation) = buffering.makeStream(of: Value.self)
      let continuationOwner = CogValuesContinuation(continuation)
      let subscription = CogValuesSubscription()
      continuation.onTermination = { @Sendable [weak subscription] _ in
        Task { @MainActor in subscription?.cancel() }
      }
      subscription.install(
        cogs.register(label: label) { reader in
          continuationOwner.continuation.yield(read(reader))
        }
      )
      return Iterator(
        iterator: stream.makeAsyncIterator(),
        subscription: subscription
      )
    }
  }

  /// Starts one independent subscription and returns its iterator.
  public func makeAsyncIterator() -> Iterator {
    makeIteratorBody()
  }

  /// The single-consumer cursor for one Cog value subscription.
  @MainActor
  public struct Iterator: @MainActor AsyncIteratorProtocol {
    /// Cog subscriptions end normally and never throw.
    public typealias Failure = Never

    /// The standard-library cursor providing suspension and wakeup.
    private var iterator: AsyncStream<Value>.Iterator

    /// Keeps the exact graph registration alive for this cursor's lifetime.
    private let subscription: CogValuesSubscription?

    /// Retains a newly registered cursor and its matching graph lifetime.
    internal init(
      iterator: AsyncStream<Value>.Iterator,
      subscription: CogValuesSubscription?
    ) {
      self.iterator = iterator
      self.subscription = subscription
    }

    /// Returns the initial settled value, then each value offered by later turns.
    public mutating func next() async -> Value? {
      var iterator = iterator
      let value = await iterator.next()
      self.iterator = iterator
      return value
    }

    /// Creates an already-ended iterator when its context no longer exists.
    fileprivate static func finished() -> Self {
      let stream = AsyncStream<Value> { continuation in continuation.finish() }
      return Self(iterator: stream.makeAsyncIterator(), subscription: nil)
    }
  }
}

/// Finishes one export stream when its graph registration releases its body.
///
/// The continuation is safe to finish from deinitialization on any executor.
/// Its generic owner has an explicit nonisolated deinitializer both for that
/// guarantee and for the package's generic-class release-build rule.
private nonisolated final class CogValuesContinuation<Value> {
  /// The standard-library producer captured only by the graph reaction body.
  let continuation: AsyncStream<Value>.Continuation

  /// Owns the continuation for exactly as long as the reaction body exists.
  init(_ continuation: AsyncStream<Value>.Continuation) {
    self.continuation = continuation
  }

  /// Ends a waiting iterator when cancellation or context teardown drops the body.
  nonisolated deinit {
    continuation.finish()
  }
}

/// Non-generic lifetime ownership behind every ``CogValues`` iterator.
///
/// Keeping the owner non-generic permits an isolated deinitializer: dropping
/// the iterator removes its dependency edges and balances its graph leases
/// synchronously when ARC releases it on the MainActor. AsyncStream's
/// termination callback also cancels promptly when a task is suspended in
/// `next()` and receives cancellation.
@MainActor
internal final class CogValuesSubscription {
  /// The registration installed when iterator creation settles its first value.
  private var token: ReactionToken?

  /// Attaches the one registration this subscription owns.
  func install(_ token: ReactionToken) {
    guard self.token == nil else {
      fatalError("A Cog value subscription installed two graph registrations.")
    }
    self.token = token
  }

  /// Removes the subscription's graph edges and releases its lifetime leases.
  func cancel() {
    token?.cancel()
    token = nil
  }

  /// Balances graph ownership when the iterator leaves the MainActor scope.
  isolated deinit {
    cancel()
  }
}

extension Cogs {
  /// Subscribes to a manual source, starting with its current settled value.
  ///
  /// Iterator creation installs an independent subscription. The first
  /// `next()` returns the source's current completed-turn value; later changed
  /// writes are offered in turn order. The subscription never gives write
  /// capability and never makes a synchronous commit wait for its reader.
  ///
  /// - Parameters:
  ///   - valueReference: The manual source value to export.
  ///   - buffering: How this iterator bounds undelivered changed values.
  /// - Returns: A lazy MainActor-isolated asynchronous value sequence.
  public func values<Value>(
    of valueReference: ManualCog<Value>,
    buffering: CogValuesBuffering = .newest(1)
  ) -> CogValues<Value> {
    CogValues(
      cogs: self,
      label: CogLabel(name: "values(of:)", fileID: #fileID, line: #line),
      buffering: buffering,
      read: { c in c[valueReference] }
    )
  }

  /// Subscribes to a derived cog, starting with its current settled value.
  ///
  /// Creating the iterator settles a cold derived graph before placing the
  /// first element. Later turns offer a value only when the declaration's
  /// equality rule reports a change. Each iterator owns its own subscription.
  ///
  /// - Parameters:
  ///   - valueReference: The derived value to settle and export.
  ///   - buffering: How this iterator bounds undelivered changed values.
  /// - Returns: A lazy MainActor-isolated asynchronous value sequence.
  public func values<Value>(
    of valueReference: Cog<Value>,
    buffering: CogValuesBuffering = .newest(1)
  ) -> CogValues<Value> {
    CogValues(
      cogs: self,
      label: CogLabel(name: "values(of:)", fileID: #fileID, line: #line),
      buffering: buffering,
      read: { c in c[valueReference] }
    )
  }

  /// Subscribes to an async cog's total value projection.
  ///
  /// The initial element is the latest accepted success, or the declaration's
  /// resting default after first demand starts its initial work. Pending and
  /// failure transitions alone do not emit; a later changed accepted value
  /// does, following the async declaration's ordinary equality rule.
  ///
  /// - Parameters:
  ///   - valueReference: The async value projection to export.
  ///   - buffering: How this iterator bounds undelivered changed values.
  /// - Returns: A lazy MainActor-isolated asynchronous value sequence.
  public func values<Value>(
    of valueReference: AsyncCog<Value>,
    buffering: CogValuesBuffering = .newest(1)
  ) -> CogValues<Value> {
    CogValues(
      cogs: self,
      label: CogLabel(name: "values(of:)", fileID: #fileID, line: #line),
      buffering: buffering,
      read: { c in c[valueReference] }
    )
  }
}
