import Cog
import CogTesting
import Testing

@MainActor
@Test func `POLICY-02 queue commits results in run order and ends newest`() async throws {
  let (cogs, m) = probedContext()
  let inputCog = ManualCog<Int>(0)
  let work = PolicyQueueControlledWork()
  let queuedCog = AsyncCog<Int>(.queue, default: -1, name: "queued") { c in
    let input = c[inputCog]
    return work.makeRun(for: input)
  }
  var successes: [Int] = []
  m.status.watch(queuedCog, initial: .run, name: "watch.queued") { _, status in
    if status.kind == .success {
      successes.append(status.value)
    }
  }
  var starts = work.starts.makeAsyncIterator()

  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) { work.succeed(0) }

  cogs.commit("request one") { c in c[inputCog] = 1 }
  #expect(await starts.next() == 1)
  cogs.commit("request two") { c in c[inputCog] = 2 }
  cogs.commit("request three") { c in c[inputCog] = 3 }

  try await resolveAsyncStatus(in: cogs) { work.succeed(1) }
  #expect(await starts.next() == 2)
  try await resolveAsyncStatus(in: cogs) { work.succeed(2) }
  #expect(await starts.next() == 3)
  try await resolveAsyncStatus(in: cogs) { work.succeed(3) }

  #expect(successes == [0, 1, 2, 3])
  #expect(cogs.peek(queuedCog) == 3)
}
