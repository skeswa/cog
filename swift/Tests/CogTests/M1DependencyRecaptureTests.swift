import Cog
import CogTesting
import Testing

// Dependency recapture is observable through selector-owned run counts and
// public reads. These tests deliberately know nothing about edge storage, so
// they keep proving the same contract when M6 swaps the correctness core.

@MainActor
@Test func `GRAPH-09 a conditional selector follows only its current branch`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let useX = ManualCog<Bool>(true)
  let x = ManualCog<Int>(1)
  let y = ManualCog<Int>(10)
  let selected = Cog<Int> { c in
    runs += 1
    return c.get(useX) ? c.get(x) : c.get(y)
  }

  #expect(cogs.read(selected) == 1)
  #expect(runs == 1)

  cogs.commit { w in w[y] = 11 }
  #expect(cogs.read(selected) == 1)
  #expect(runs == 1)

  cogs.commit { w in w[x] = 2 }
  #expect(cogs.read(selected) == 2)
  #expect(runs == 2)

  cogs.commit { w in w[useX] = false }
  #expect(cogs.read(selected) == 11)
  #expect(runs == 3)

  cogs.commit { w in w[y] = 12 }
  #expect(cogs.read(selected) == 12)
  #expect(runs == 4)

  cogs.commit { w in w[x] = 3 }
  #expect(cogs.read(selected) == 12)
  #expect(runs == 4)
}

@MainActor
@Test func `GRAPH-10 an early return captures a later dependency when reached`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let includeZ = ManualCog<Bool>(false)
  let z = ManualCog<Int>(1)
  let selected = Cog<Int> { c in
    runs += 1
    guard c.get(includeZ) else { return -1 }
    return c.get(z)
  }

  #expect(cogs.read(selected) == -1)
  #expect(runs == 1)

  cogs.commit { w in w[z] = 2 }
  #expect(cogs.read(selected) == -1)
  #expect(runs == 1)

  cogs.commit { w in w[includeZ] = true }
  #expect(cogs.read(selected) == 2)
  #expect(runs == 2)

  cogs.commit { w in w[z] = 3 }
  #expect(cogs.read(selected) == 3)
  #expect(runs == 3)
}
