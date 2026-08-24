import Cog
import CogTesting
import Testing

@MainActor
@Test func `POLICY-04 merged runs overlap and publish in landing order`() async throws {
  let (cogs, m) = probedContext()
  let inputCog = Cog<Int>.Manual { 0 }
  let work = PolicyGenerationControlledWork()
  let mergedCog = Cog<Int>.Async(.merged, default: -1, name: "merged") { c in
    _ = c[inputCog]
    return work.makeRun()
  }
  var successes: [Int] = []
  m.status.watch(mergedCog, initial: .run, name: "watch.merged") { _, status in
    if status.kind == .success {
      successes.append(status.value)
    }
  }
  var starts = work.starts.makeAsyncIterator()

  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) { work.succeed(0, with: 0) }

  cogs.turn("request one") { c in c[inputCog] = 1 }
  cogs.turn("request two") { c in c[inputCog] = 2 }
  #expect(await starts.next() == 1)
  #expect(await starts.next() == 2)

  try await resolveAsyncStatus(in: cogs) { work.succeed(2, with: 20) }
  try await resolveAsyncStatus(in: cogs) { work.succeed(1, with: 10) }

  #expect(successes == [0, 20, 10])
  #expect(cogs.peek(mergedCog) == 10)
}
