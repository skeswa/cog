import Cog
import CogTesting
import Testing

@MainActor
@Test func `POLICY-02 queue publishes results in run order and ends newest`() async throws {
  let (cogs, m) = probedContext()
  let inputCog = Cog<Int>.Manual(0)
  let work = PolicyQueueControlledWork()
  let queuedCog = Cog<Int>.Async(.queue, default: -1, name: "queued") { c in
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

  cogs.turn("request one") { c in c[inputCog] = 1 }
  #expect(await starts.next() == 1)
  cogs.turn("request two") { c in c[inputCog] = 2 }
  cogs.turn("request three") { c in c[inputCog] = 3 }

  try await resolveAsyncStatus(in: cogs) { work.succeed(1) }
  #expect(await starts.next() == 2)
  try await resolveAsyncStatus(in: cogs) { work.succeed(2) }
  #expect(await starts.next() == 3)
  try await resolveAsyncStatus(in: cogs) { work.succeed(3) }

  #expect(successes == [0, 1, 2, 3])
  #expect(cogs.peek(queuedCog) == 3)
}
