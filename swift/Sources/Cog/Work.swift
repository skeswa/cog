/// Deferred async work selected for one ``Cog.Async`` generation.
///
/// `Work` describes execution; creating it does not start a `Task`. An async
/// selector returns either a one-shot operation or an async sequence after
/// synchronously recording its Cog dependencies. Cog then owns iteration,
/// cancellation, generation checks, and MainActor publication of resulting
/// statuses.
///
/// The operation may throw and may return a non-`Sendable` value when Swift's
/// region-based `sending` rules prove the transfer safe. Replacement and
/// lifetime cancellation are advisory to the operation, but Cog rejects every
/// completion that no longer belongs to the current stored generation. `Work`
/// itself is a description rather than a task handle: callers cannot start,
/// await, or cancel it directly.
public struct Work<Value> {
  /// The physical work description consumed by the async runtime.
  internal let storage: WorkStorage<Value>

  /// Stores a work shape without starting it.
  internal init(storage: WorkStorage<Value>) {
    self.storage = storage
  }

  /// Describes one deferred, throwing value-producing operation.
  ///
  /// The body does not run during this call. An unannotated body inherits the
  /// surrounding actor, normally the MainActor of an async selector, which is
  /// useful for async APIs isolated there. Executor-independent work can use an
  /// explicitly `@concurrent` body to opt into the generic executor instead;
  /// blocking a cooperative Swift executor remains inappropriate on either.
  ///
  /// Regardless of operation isolation, Cog observes completion and publishes
  /// success or failure on the MainActor. If newer work or lifetime release has
  /// superseded this operation, its completion publishes nothing.
  ///
  /// - Parameter operation: The deferred operation for this generation. It
  ///   should cooperate with cancellation when practical, though correctness
  ///   does not depend on that cooperation.
  /// - Returns: A work description for the async selector to return to Cog.
  public static func run(
    @_inheritActorContext
    _ operation: sending @escaping @Sendable @isolated(any) () async throws -> sending Value
  ) -> Self {
    Self(storage: .run(operation))
  }

  /// Describes an async sequence whose changed elements become Cog turns.
  ///
  /// Constructing this value does not start iteration. Cog owns the iterator
  /// after the selector returns, applies latest-generation cancellation, and
  /// publishes accepted elements on the MainActor. The selector overloads
  /// expose this factory only under ``LatestPolicy``; ``RunWork`` deliberately
  /// has no corresponding member, so ordered stream policies are impossible to
  /// spell.
  ///
  /// - Parameter sequence: The sequence selected for this generation.
  /// - Returns: A stream work description for a latest-policy async cog.
  public static func stream<Sequence: AsyncSequence>(_ sequence: Sequence) -> Self
  where Sequence.Element == Value {
    Self(storage: .stream(WorkStream(sequence)))
  }

  /// Promotes one-shot-only work into the latest policy's broader work type.
  internal init(_ runWork: RunWork<Value>) {
    self.init(storage: .run(runWork.operation))
  }
}

/// A one-shot async operation accepted by ordered scheduling policies.
///
/// `RunWork` is intentionally narrower than ``Work``. It can describe only one
/// value-producing operation, so a selector whose policy is ``OrderedPolicy``
/// cannot return a stream even accidentally. Cog promotes this description to
/// its internal work representation only after the public type checker has
/// enforced that boundary.
public struct RunWork<Value> {
  /// The deferred operation with the isolation inherited at its declaration.
  internal let operation: @Sendable @isolated(any) () async throws -> sending Value

  /// Describes one deferred, throwing value-producing operation.
  ///
  /// The body does not run during this call. It inherits the surrounding actor
  /// unless explicitly declared `@concurrent`; Cog observes its completion and
  /// publishes the accepted result on the MainActor.
  ///
  /// - Parameter operation: The operation for one ordered generation.
  /// - Returns: One-shot work that cannot be used to describe a stream.
  public static func run(
    @_inheritActorContext
    _ operation: sending @escaping @Sendable @isolated(any) () async throws -> sending Value
  ) -> Self {
    Self(operation: operation)
  }
}

/// The internal tagged storage that preserves one-shot versus stream shape.
///
/// Stream storage owns a lazy type-erased iterator factory. Storage never
/// crosses the MainActor merely because it is wrapped in ``Work``; execution
/// isolation remains a property of the operation or sequence itself.
internal enum WorkStorage<Value> {
  /// One deferred value-producing operation.
  case run(@Sendable @isolated(any) () async throws -> sending Value)

  /// One selected async sequence, retained behind a lazy iterator factory.
  case stream(WorkStream<Value>)
}

/// A type-erased async sequence that remains inert until Cog asks for an iterator.
///
/// The factory and iterator stay MainActor-confined, matching selector and
/// publication isolation while allowing the underlying sequence and iterator
/// to remain non-`Sendable`. This erasure exposes only `next`; callers cannot
/// recover or drive the original sequence outside Cog's generation checks.
internal struct WorkStream<Value> {
  /// Creates one type-erased iterator when the selected generation starts.
  private let makeIteratorBody: @MainActor () -> WorkStreamIterator<Value>

  /// Retains a sequence without constructing its iterator or starting work.
  init<Sequence: AsyncSequence>(_ sequence: Sequence) where Sequence.Element == Value {
    makeIteratorBody = {
      let storage = WorkStreamIteratorStorage(sequence.makeAsyncIterator())
      return WorkStreamIterator { try await storage.next() }
    }
  }

  /// Creates the sole iterator owned by one running stream generation.
  func makeIterator() -> WorkStreamIterator<Value> {
    makeIteratorBody()
  }
}

/// The type-erased iterator driven by one Cog-owned stream task.
internal final class WorkStreamIterator<Value> {
  /// Advances the concrete iterator while preserving MainActor confinement.
  private let nextBody: @MainActor () async throws -> Value?

  /// Erases one concrete iterator's advancing closure.
  init(next: @escaping @MainActor () async throws -> Value?) {
    nextBody = next
  }

  /// Returns the next element or natural end from the underlying sequence.
  func next() async throws -> Value? {
    try await nextBody()
  }

  // Written explicitly per the generic-class release-build rule.
  nonisolated deinit {}
}

/// Single-consumer storage for a concrete iterator whose `next` may be concurrent.
///
/// `AsyncIteratorProtocol.next` is executor-independent on the deployment
/// floor, so the iterator cannot remain an actor-isolated stored property across
/// that suspension. Cog supplies the synchronization invariant instead: this
/// box is private to one stream task, and that task never calls `next` again
/// until the preceding call returns. The unchecked conformance expresses only
/// that exclusive ownership; it does not make the iterator generally shareable.
private nonisolated final class WorkStreamIteratorStorage<Iterator: AsyncIteratorProtocol>:
  @unchecked Sendable
{
  /// The iterator moved into a task-local value for each exclusive advance.
  private var iterator: Iterator

  /// Takes exclusive ownership of one freshly created iterator.
  init(_ iterator: consuming Iterator) {
    self.iterator = iterator
  }

  /// Advances once under the owning stream task's no-overlap invariant.
  func next() async throws -> Iterator.Element? {
    var iterator = self.iterator
    let element = try await iterator.next()
    self.iterator = iterator
    return element
  }

  // Written explicitly per the generic-class release-build rule.
  nonisolated deinit {}
}

/// How an async state schedules new work while prior work is in flight.
///
/// Policies are part of declaration behavior and apply independently to each
/// key of an ``CogBox.Async``. The policy is `nonisolated` and `Sendable`;
/// choosing one does not access a context or start work. Latest selectors may
/// return either ``Work/run(_:)`` or ``Work/stream(_:)``.
public nonisolated enum LatestPolicy: Sendable, Equatable {
  /// Cancel prior work and accept a result only from the newest generation.
  ///
  /// Every reload publishes pending as its next visible status, advances a
  /// monotonically increasing generation, and requests cancellation of the old
  /// task. If the old task ignores cancellation and completes, the generation
  /// check discards its result. Replacement cancellation itself never publishes
  /// failure.
  case latest

  /// The runtime tag shared with ordered policy declarations.
  internal var schedulingPolicy: AsyncSchedulingPolicy { .latest }
}

/// How one-shot async state schedules new work without cancelling the current run.
///
/// Ordered selectors return ``RunWork``, which makes stream work unavailable at
/// compile time. Each policy applies independently to every key of an
/// ``CogBox.Async``. Selecting a policy is inert; the context starts work only
/// when that value reference is demanded.
public nonisolated enum OrderedPolicy: Sendable, Equatable {
  /// Run every accepted request one at a time in input order.
  case queue

  /// Finish the current run, coalesce intervening changes, then catch up once.
  case exhaustLatest

  /// Allow accepted runs to overlap and publish each result when it lands.
  case merged

  /// The runtime tag shared with latest policy declarations.
  internal var schedulingPolicy: AsyncSchedulingPolicy {
    switch self {
    case .queue: .queue
    case .exhaustLatest: .exhaustLatest
    case .merged: .merged
    }
  }
}

/// The policy tag retained by descriptors after public work-shape checking.
///
/// Public policy types stay split so selector result types enforce valid work.
/// The runtime needs one closed tag after construction to dispatch scheduling
/// without retaining two otherwise parallel descriptor families.
internal nonisolated enum AsyncSchedulingPolicy: Sendable, Equatable {
  /// Replace older work.
  case latest

  /// Drain every request in order.
  case queue

  /// Coalesce while busy and catch up once.
  case exhaustLatest

  /// Run requests concurrently.
  case merged
}
