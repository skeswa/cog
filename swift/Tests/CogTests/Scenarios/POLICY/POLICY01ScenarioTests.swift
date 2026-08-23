import Cog
import CogTesting
import Testing

@MainActor
@Test func `POLICY-01 queue runs every dependency input serially in FIFO order`() async throws {
  let (cogs, m) = probedContext()
  let inputCog = Cog<Int>.Manual(0)
  let work = PolicyQueueControlledWork()
  let queuedCog = Cog<Int>.Async(.queue, default: -1, name: "queued") { c in
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

  cogs.turn("request one") { c in c[inputCog] = 1 }
  #expect(await starts.next() == 1)
  let pendingCountBeforeQueueing = statusKinds.count(where: { $0 == .pending })

  cogs.turn("request two") { c in c[inputCog] = 2 }
  cogs.turn("request three") { c in c[inputCog] = 3 }

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
