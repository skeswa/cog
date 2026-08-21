import Cog
import CogTesting
import Testing

/// One observable entry into a controlled stream iterator.
nonisolated struct DependencyStreamStart: Sendable, Equatable {
  /// The stream generation whose iterator requested an element.
  let generation: Int

  /// The dependency value captured when that generation was selected.
  let dependency: Int
}

/// Cancellation-ignoring rendezvous storage shared by controlled iterators.
///
/// Checked continuations deliberately do not react to task cancellation. That
/// lets the old iterator return a late element after Cog has cancelled it, so
/// the scenario reaches Cog's generation check instead of relying on sequence
/// cancellation to discard the element first.
actor DependencyStreamChannel {
  /// Publishes every request for a next element.
  let startContinuation: AsyncStream<DependencyStreamStart>.Continuation

  /// One suspended `next()` call per live test generation.
  private var waiters: [Int: CheckedContinuation<Int?, Never>] = [:]

  init(startContinuation: AsyncStream<DependencyStreamStart>.Continuation) {
    self.startContinuation = startContinuation
  }

  /// Suspends one iterator advance until the test supplies an element or end.
  func next(generation: Int, dependency: Int) async -> Int? {
    startContinuation.yield(
      DependencyStreamStart(generation: generation, dependency: dependency)
    )
    return await withCheckedContinuation { waiter in
      waiters[generation] = waiter
    }
  }

  /// Resumes the exact generation currently waiting for its next element.
  func send(_ value: Int?, to generation: Int) {
    guard let waiter = waiters.removeValue(forKey: generation) else {
      fatalError("Generation \(generation) was not waiting for a stream element.")
    }
    waiter.resume(returning: value)
  }
}

/// A controlled sequence that reports cancellation but still permits a late element.
nonisolated struct DependencyStreamSequence: AsyncSequence, Sendable {
  typealias Element = Int

  /// The selector generation represented by this sequence.
  let generation: Int

  /// The dependency captured synchronously for this generation.
  let dependency: Int

  /// Owns the cancellation-ignoring suspension for each iterator advance.
  let channel: DependencyStreamChannel

  /// Reports Cog's cancellation request independently of element delivery.
  let cancellationContinuation: AsyncStream<Int>.Continuation

  func makeAsyncIterator() -> Iterator {
    Iterator(
      generation: generation,
      dependency: dependency,
      channel: channel,
      cancellationContinuation: cancellationContinuation
    )
  }

  /// The single consumer iterator owned by one Cog generation.
  struct Iterator: AsyncIteratorProtocol {
    /// The selector generation represented by this iterator.
    let generation: Int

    /// The dependency captured synchronously for this generation.
    let dependency: Int

    /// Owns the cancellation-ignoring suspension for each iterator advance.
    let channel: DependencyStreamChannel

    /// Reports Cog's cancellation request independently of element delivery.
    let cancellationContinuation: AsyncStream<Int>.Continuation

    mutating func next() async -> Int? {
      let generation = generation
      let dependency = dependency
      let channel = channel
      let cancellationContinuation = cancellationContinuation
      return await withTaskCancellationHandler {
        await channel.next(generation: generation, dependency: dependency)
      } onCancel: {
        cancellationContinuation.yield(generation)
      }
    }
  }
}

@MainActor
final class DependencyStreamWork {
  /// Announces each iterator request together with its captured dependency.
  let starts: AsyncStream<DependencyStreamStart>

  /// Announces generations whose stream task Cog cancelled.
  let cancellations: AsyncStream<Int>

  /// Backs ``cancellations`` and is copied into each selected sequence.
  private let cancellationContinuation: AsyncStream<Int>.Continuation

  /// Owns suspended iterator advances across every selected generation.
  private let channel: DependencyStreamChannel

  /// The generation assigned to the next selector run.
  private var nextGeneration = 0

  init() {
    let (starts, startContinuation) = AsyncStream.makeStream(of: DependencyStreamStart.self)
    let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Int.self)
    self.starts = starts
    self.cancellations = cancellations
    self.cancellationContinuation = cancellationContinuation
    channel = DependencyStreamChannel(startContinuation: startContinuation)
  }

  /// Creates one sequence carrying the dependency captured by its selector run.
  func makeWork(dependency: Int) -> Work<Int> {
    let generation = nextGeneration
    nextGeneration += 1
    return .stream(
      DependencyStreamSequence(
        generation: generation,
        dependency: dependency,
        channel: channel,
        cancellationContinuation: cancellationContinuation
      )
    )
  }

  /// Delivers an element, or `nil` for natural end, to one waiting generation.
  func send(_ value: Int?, to generation: Int) async {
    await channel.send(value, to: generation)
  }

  nonisolated deinit {}
}

@MainActor
@Test func `STREAM-03 dependency replacement cancels and rejects the old stream`() async throws {
  let (cogs, m) = probedContext()
  let request = ManualCog<Int>(0)
  let work = DependencyStreamWork()
  let readingsCog = AsyncCog<Int>(.latest, default: -1, name: "readings") { c in
    let request = c[request]
    return work.makeWork(dependency: request)
  }
  var statuses: [CogStatus<Int>] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.readings") { _, status in
    statuses.append(status)
  }
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  let initialStart = await startIterator.next()
  #expect(initialStart == DependencyStreamStart(generation: 0, dependency: 0))

  cogs.turn("change request") { c in c[request] = 1 }
  #expect(await cancellationIterator.next() == 0)
  let replacementStart = await startIterator.next()
  #expect(replacementStart == DependencyStreamStart(generation: 1, dependency: 1))

  let lateChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: lateChecked)
  await work.send(99, to: 0)
  try await lateChecked.wait()
  let afterLate = cogs.status.peek(readingsCog)
  #expect(afterLate.kind == .pending)
  #expect(afterLate.value == -1)
  #expect(!afterLate.hasSucceeded)
  #expect(statuses.map(\.kind) == [.pending, .pending])

  let acceptedChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: acceptedChecked)
  await work.send(20, to: 1)
  try await acceptedChecked.wait()
  let accepted = cogs.status.peek(readingsCog)
  #expect(accepted.kind == .success)
  #expect(accepted.value == 20)
  #expect(statuses.map(\.value) == [-1, -1, 20])

  let nextStart = await startIterator.next()
  #expect(nextStart == DependencyStreamStart(generation: 1, dependency: 1))
  let ended = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: ended)
  await work.send(nil, to: 1)
  try await ended.wait()
}
