public import Cog

/// Deterministic, generation-indexed stream work for tests.
///
/// The stream counterpart of ``ControlledWork``: each ``makeWork()`` call
/// creates one inert stream generation, ``starts`` announces the generation
/// when Cog begins consuming it, and the test drives that exact generation
/// with ``yield(_:to:)``, ``finish(_:)``, and ``fail(_:with:)``:
///
/// ```swift
/// let work = ControlledStream<Int>()
/// let readingsCog = Cog<Int>.Async(.latest, default: -1, name: "readings") { _ in
///   work.makeWork()
/// }
/// var starts = work.starts.makeAsyncIterator()
///
/// cogs.refresh(readingsCog)
/// #expect(await starts.next() == 0)
/// work.yield(5, to: 0)
/// ```
///
/// Unlike one-shot completion, elements yielded before consumption begins are
/// buffered by the underlying stream rather than lost, so awaiting ``starts``
/// is how a test proves a generation went live — after a refresh replaced the
/// previous one, say — not how it avoids losing elements. Elements pass
/// through Cog's ordinary generation checks and equality gating; observing an
/// accepted publication remains the acknowledgement hooks' job.
///
/// Identity and lifetime are the test's: the controller is a MainActor class
/// the test retains alongside its runtime, and it holds one continuation per
/// generation it has created.
@MainActor
public final class ControlledStream<Value: Sendable> {
  /// The generation IDs whose streams Cog has begun consuming, in order.
  public let starts: AsyncStream<Int>

  /// Publishes each generation when its consumption begins.
  private let startContinuation: AsyncStream<Int>.Continuation

  /// The live continuation for each generation created so far.
  private var continuations: [AsyncThrowingStream<Value, any Error>.Continuation] = []

  /// Creates an empty controller whose first created generation is zero.
  public init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  /// Returns stream work whose consumption announces its assigned generation.
  ///
  /// Call this from a latest-policy async selector, once per selector run.
  /// The generation is assigned here; ``starts`` announces it when Cog asks
  /// the sequence for its iterator, which is the moment the generation's
  /// stream task begins.
  public func makeWork() -> Work<Value> {
    let generation = continuations.count
    let (sequence, continuation) = AsyncThrowingStream<Value, any Error>.makeStream()
    continuations.append(continuation)
    return .stream(
      StartAnnouncingStream(
        base: sequence,
        generation: generation,
        announce: startContinuation
      )
    )
  }

  /// Offers one element to the requested generation.
  ///
  /// Elements offered before consumption starts are buffered; elements offered
  /// after the generation finished, failed, or was cancelled are dropped by
  /// the underlying stream.
  public func yield(_ value: Value, to generation: Int) {
    continuation(for: generation).yield(value)
  }

  /// Ends the requested generation normally, with no element.
  public func finish(_ generation: Int) {
    continuation(for: generation).finish()
  }

  /// Terminates the requested generation with an error.
  public func fail(_ generation: Int, with error: any Error) {
    continuation(for: generation).finish(throwing: error)
  }

  /// Resolves a generation index or names the mistake instead of trapping on
  /// an array bound, since the index is test-authored input.
  private func continuation(for generation: Int)
    -> AsyncThrowingStream<Value, any Error>
    .Continuation
  {
    guard continuations.indices.contains(generation) else {
      fatalError(
        "ControlledStream was asked to drive generation \(generation), but only "
          + "\(continuations.count) generation(s) have been created by makeWork()."
      )
    }
    return continuations[generation]
  }

  // Written explicitly per the generic-class release-build rule.
  nonisolated deinit {}
}

/// A sequence that reports the instant Cog begins consuming its base.
///
/// Cog asks a selected stream for its iterator exactly once, on the MainActor,
/// when the generation's stream task starts; announcing there is what makes
/// ``ControlledStream/starts`` mean "consumption began" rather than "the
/// selector ran". The wrapper is otherwise transparent: iteration is the
/// base stream's own.
private struct StartAnnouncingStream<Element: Sendable>: AsyncSequence {
  /// The controlled stream one generation owns.
  let base: AsyncThrowingStream<Element, any Error>

  /// The generation announced when consumption begins.
  let generation: Int

  /// Where the owning controller publishes consumption starts.
  let announce: AsyncStream<Int>.Continuation

  /// Announces the generation, then hands iteration to the base stream.
  func makeAsyncIterator() -> AsyncThrowingStream<Element, any Error>.AsyncIterator {
    announce.yield(generation)
    return base.makeAsyncIterator()
  }
}
