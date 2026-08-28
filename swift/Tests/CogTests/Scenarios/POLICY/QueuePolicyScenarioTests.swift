import Cog
import CogTesting
import Testing

@MainActor
@Test func `POLICY-01 queue runs every dependency input serially in FIFO order`() async throws {
  let (cogs, m) = Cogs.forTestingWithController()
  let inputCog = Cog<Int>.Manual { 0 }
  let work = PolicyQueueControlledWork()
  let queuedCog = Cog<Int>.Async(.queue, default: -1, name: "queued") { c in
    let input = c[inputCog]
    return work.makeRun(for: input)
  }
  var statusKinds: [CogStatus<Int>.Kind] = []
  var successes: [Int] = []
  m.status.watch(queuedCog, initial: .run, name: "watch.queued") { _, status in
    statusKinds.append(status.kind)
    if status.kind == .success {
      successes.append(status.value)
    }
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

  // A trailing input closes the "exactly three additional runs" promise: the
  // queue is serial FIFO, so any spurious extra run would have to start before
  // this one, and the next observed start would not be 4.
  cogs.turn("request four") { c in c[inputCog] = 4 }
  guard await starts.next() == 4 else {
    work.finishAll()
    Issue.record("A spurious run started after the queued inputs drained")
    return
  }
  try await resolveAsyncStatus(in: cogs) { work.succeed(4) }

  // The retired POLICY-02 rode this same harness: serial FIFO execution means
  // results publish in run order and the final value matches the newest input.
  #expect(successes == [0, 1, 2, 3, 4])
  #expect(cogs.peek(queuedCog) == 4)
}
