import Cog

/// Deterministic queued runs indexed by the dependency input they capture.
@MainActor
final class PolicyQueueControlledWork {
  /// Announces only when an operation actually begins executing.
  let starts: AsyncStream<Int>

  /// Feeds operation starts to the test in exact execution order.
  private let startContinuation: AsyncStream<Int>.Continuation

  /// One cancellable suspension gate per selected input.
  private var gates: [Int: AsyncStream<Void>.Continuation] = [:]

  /// Creates a probe with no selected or running work.
  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  /// Describes one run that announces its input and waits for explicit success.
  func makeRun(for input: Int) -> RunWork<Int> {
    let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
    gates[input] = gateContinuation
    return .run {
      self.startContinuation.yield(input)
      var iterator = gate.makeAsyncIterator()
      guard await iterator.next() != nil else { throw CancellationError() }
      return input
    }
  }

  /// Lets one exact input finish successfully.
  func succeed(_ input: Int) {
    gates.removeValue(forKey: input)?.yield()
  }

  /// Releases every suspension when an assertion must end the test early.
  func finishAll() {
    for gate in gates.values {
      gate.finish()
    }
    gates.removeAll()
  }

  nonisolated deinit {}
}
