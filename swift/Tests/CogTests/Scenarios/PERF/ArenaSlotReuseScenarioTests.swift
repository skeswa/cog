import Cog
import CogTesting
import Testing

@MainActor
@Test func `PERF-05 a released arena slot is reused at a new generation`() {
  let cogs = Cogs.forTesting()
  let releasedCog = Cog<Int>({ _ in 41 }, name: "released")
  let replacementCog = Cog<String>({ _ in "replacement" }, name: "replacement")

  let reuse = cogs.probeArenaSlotReuse(
    releasing: releasedCog,
    replacingWith: replacementCog
  )

  #expect(reuse.reusedIndex)
  #expect(reuse.changedGeneration)
  #expect(reuse.replacementGeneration == reuse.releasedGeneration + 1)
  #expect(cogs.peek(replacementCog) == "replacement")
}

@MainActor
@Test func `PERF-05 stale arena access fails instead of reaching the replacement`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      let releasedCog = Cog<Int>({ _ in 41 }, name: "released")
      let replacementCog = Cog<Int>({ _ in 42 }, name: "replacement")

      cogs.trapOnStaleArenaSlotAccess(
        releasing: releasedCog,
        replacingWith: replacementCog
      )
    }
  }

  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("Cog tried to use stale arena slot 0 at generation 0."))
}
