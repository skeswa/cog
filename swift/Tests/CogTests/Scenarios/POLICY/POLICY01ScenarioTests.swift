import Cog
import CogTesting
import Testing

/// Deterministic one-shot runs indexed by the dependency value they captured.
@MainActor
private final class Policy01ControlledWork {
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

@MainActor
@Test func `POLICY-01 queue runs every dependency input serially in FIFO order`() async throws {
  let (cogs, m) = probedContext()
  let inputCog = ManualCog<Int>(0)
  let work = Policy01ControlledWork()
  let queuedCog = AsyncCog<Int>(.queue, default: -1, name: "queued") { c in
    let input = c[inputCog]
    return work.makeRun(for: input)
  }
  var statusKinds: [CogStatus<Int>.Kind] = []
  m.status.watch(queuedCog, initial: .run, name: "watch.queued") { _, status in
    statusKinds.append(status.kind)
  }
  var starts = work.starts.makeAsyncIterator()

  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) { work.succeed(0) }

  cogs.commit("request one") { c in c[inputCog] = 1 }
  #expect(await starts.next() == 1)
  let pendingCountBeforeQueueing = statusKinds.count(where: { $0 == .pending })

  cogs.commit("request two") { c in c[inputCog] = 2 }
  cogs.commit("request three") { c in c[inputCog] = 3 }

  guard statusKinds.count(where: { $0 == .pending }) == pendingCountBeforeQueueing else {
    work.finishAll()
    Issue.record("Queued inputs published pending and started before the active run finished")
    return
  }

  try await resolveAsyncStatus(in: cogs) { work.succeed(1) }
  #expect(await starts.next() == 2)
  try await resolveAsyncStatus(in: cogs) { work.succeed(2) }
  #expect(await starts.next() == 3)
  try await resolveAsyncStatus(in: cogs) { work.succeed(3) }
}
