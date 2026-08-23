import Cog
import CogTesting
import Testing

@MainActor
@Test func `POLICY-03 exhaust coalesces a burst into one newest catch-up`() async throws {
  let (cogs, m) = probedContext()
  let inputCog = Cog<Int>.Manual(0)
  let work = PolicyQueueControlledWork()
  let exhaustedCog = Cog<Int>.Async(.exhaustLatest, default: -1, name: "exhausted") { c in
    let input = c[inputCog]
    return work.makeRun(for: input)
  }
  var statusKinds: [CogStatus<Int>.Kind] = []
  var successes: [Int] = []
  m.status.watch(exhaustedCog, initial: .run, name: "watch.exhausted") { _, status in
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
  let pendingCountBeforeBurst = statusKinds.count(where: { $0 == .pending })

  for input in 2...11 {
    cogs.turn("request \(input)") { c in c[inputCog] = input }
  }

  guard statusKinds.count(where: { $0 == .pending }) == pendingCountBeforeBurst else {
    work.finishAll()
    Issue.record("Exhaust started replacement work before the active run finished")
    return
  }

  try await resolveAsyncStatus(in: cogs) { work.succeed(1) }
  #expect(await starts.next() == 11)
  try await resolveAsyncStatus(in: cogs) { work.succeed(11) }

  #expect(successes == [0, 1, 11])
  #expect(cogs.peek(exhaustedCog) == 11)
}
