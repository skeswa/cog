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

@MainActor
@Test func `GRAPH-11 removing a list item drops its keyed dependency`() {
  let cogs = Cogtext.forTesting()
  let members = ManualCogBox<[Int], String>([1, 2, 3])
  let scores = ManualCogBox<Int, Int> { item in item * 10 }
  var runs = 0

  let totals = CogBox<Int, String> { c, group in
    runs += 1
    return c.get(members[group]).reduce(into: 0) { total, item in
      total += c.get(scores[item])
    }
  }

  #expect(cogs.read(totals["friends"]) == 60)
  #expect(runs == 1)

  cogs.commit { w in w[members["friends"]] = [1, 3] }
  #expect(cogs.read(totals["friends"]) == 40)
  #expect(runs == 2)

  cogs.commit { w in w[scores[2]] = 200 }
  #expect(cogs.read(scores[2]) == 200)
  #expect(cogs.read(totals["friends"]) == 40)
  #expect(runs == 2)

  cogs.commit { w in w[scores[1]] = 100 }
  #expect(cogs.read(totals["friends"]) == 130)
  #expect(runs == 3)
}

@MainActor
@Test func `GRAPH-12 a ref through ref follows the new key and drops the old one`() {
  let cogs = Cogtext.forTesting()
  let currentZip = ManualCog<String>("90210")
  let weather = ManualCogBox<Int, String> { zip in
    zip == "90210" ? 72 : 41
  }
  var runs = 0

  let currentTemperature = Cog<Int> { c in
    runs += 1
    let zip = c.get(currentZip)
    return c.get(weather[zip])
  }

  #expect(cogs.read(currentTemperature) == 72)
  #expect(runs == 1)

  cogs.commit { w in w[currentZip] = "10001" }
  #expect(cogs.read(currentTemperature) == 41)
  #expect(runs == 2)

  cogs.commit { w in w[weather["10001"]] = 50 }
  #expect(cogs.read(currentTemperature) == 50)
  #expect(runs == 3)

  cogs.commit { w in w[weather["90210"]] = 99 }
  #expect(cogs.read(weather["90210"]) == 99)
  #expect(cogs.read(currentTemperature) == 50)
  #expect(runs == 3)
}
