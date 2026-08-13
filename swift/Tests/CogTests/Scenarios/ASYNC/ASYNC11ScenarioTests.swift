import Cog
import CogTesting
import Testing

@MainActor
private final class Async11WorkProbe {
  struct Observation: Equatable {
    let selectorValue: Int
    let workValue: Int
  }

  private var nextRunID = 0
  private var suspendedRuns: Set<Int> = []
  private var suspensionWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
  private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
  private var completedRuns: Set<Int> = []
  private var completionWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

  private(set) var observations: [Observation] = []

  func run(
    selectorValue: Int,
    cogs: Cogs,
    workValue: ManualCog<Int>
  ) async -> Int {
    nextRunID += 1
    let runID = nextRunID

    await withCheckedContinuation { continuation in
      releaseContinuations[runID] = continuation
      suspendedRuns.insert(runID)
      suspensionWaiters.removeValue(forKey: runID)?.resume()
    }

    let value = cogs.peek(workValue)
    observations.append(Observation(selectorValue: selectorValue, workValue: value))
    completedRuns.insert(runID)
    completionWaiters.removeValue(forKey: runID)?.resume()
    return selectorValue + value
  }

  func waitUntilSuspended(_ runID: Int) async {
    guard !suspendedRuns.contains(runID) else { return }
    await withCheckedContinuation { suspensionWaiters[runID] = $0 }
  }

  func release(_ runID: Int) {
    guard let continuation = releaseContinuations.removeValue(forKey: runID) else {
      fatalError("Async work run \(runID) was released before it suspended.")
    }
    continuation.resume()
  }

  func waitUntilCompleted(_ runID: Int) async {
    guard !completedRuns.contains(runID) else { return }
    await withCheckedContinuation { completionWaiters[runID] = $0 }
  }
}

@MainActor
@Test func `ASYNC-11 only synchronous selector reads become dependencies`() async throws {
  let cogs = Cogs.forTesting()
  let selectorInput = ManualCog<Int>(10)
  let workInput = ManualCog<Int>(20)
  let probe = Async11WorkProbe()
  var selectorValues: [Int] = []

  let result = AsyncCog<Int>(default: 0) { c in
    let selectorValue = c[selectorInput]
    selectorValues.append(selectorValue)
    return .run {
      await probe.run(
        selectorValue: selectorValue,
        cogs: cogs,
        workValue: workInput
      )
    }
  }

  let token = cogs.run { c in _ = c[result] }
  #expect(selectorValues == [10])

  await probe.waitUntilSuspended(1)
  cogs.commit { c in c[workInput] = 21 }
  probe.release(1)
  await probe.waitUntilCompleted(1)
  #expect(probe.observations == [.init(selectorValue: 10, workValue: 21)])

  cogs.commit { c in c[workInput] = 22 }
  #expect(selectorValues == [10])

  cogs.commit { c in c[selectorInput] = 11 }
  try #require(selectorValues == [10, 11])

  await probe.waitUntilSuspended(2)
  probe.release(2)
  await probe.waitUntilCompleted(2)
  #expect(
    probe.observations == [
      .init(selectorValue: 10, workValue: 21),
      .init(selectorValue: 11, workValue: 22),
    ]
  )
  withExtendedLifetime(token) {}
}
