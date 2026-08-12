import Cog
import CogTesting
import Testing

// Selector-owned counters make dependency recapture visible through public
// reads.

@MainActor
@Test func `GRAPH-09 a conditional selector follows only its current branch`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let useX = ManualCog<Bool>(true)
  let x = ManualCog<Int>(1)
  let y = ManualCog<Int>(10)
  let selected = Cog<Int> { c in
    runs += 1
    return c[useX] ? c[x] : c[y]
  }

  #expect(cogs.peek(selected) == 1)
  #expect(runs == 1)

  cogs.commit { c in c[y] = 11 }
  #expect(cogs.peek(selected) == 1)
  #expect(runs == 1)

  cogs.commit { c in c[x] = 2 }
  #expect(cogs.peek(selected) == 2)
  #expect(runs == 2)

  cogs.commit { c in c[useX] = false }
  #expect(cogs.peek(selected) == 11)
  #expect(runs == 3)

  cogs.commit { c in c[y] = 12 }
  #expect(cogs.peek(selected) == 12)
  #expect(runs == 4)

  cogs.commit { c in c[x] = 3 }
  #expect(cogs.peek(selected) == 12)
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
    guard c[includeZ] else { return -1 }
    return c[z]
  }

  #expect(cogs.peek(selected) == -1)
  #expect(runs == 1)

  cogs.commit { c in c[z] = 2 }
  #expect(cogs.peek(selected) == -1)
  #expect(runs == 1)

  cogs.commit { c in c[includeZ] = true }
  #expect(cogs.peek(selected) == 2)
  #expect(runs == 2)

  cogs.commit { c in c[z] = 3 }
  #expect(cogs.peek(selected) == 3)
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
    return c[members[group]].reduce(into: 0) { total, item in
      total += c[scores[item]]
    }
  }

  #expect(cogs.peek(totals["friends"]) == 60)
  #expect(runs == 1)

  cogs.commit { c in c[members["friends"]] = [1, 3] }
  #expect(cogs.peek(totals["friends"]) == 40)
  #expect(runs == 2)

  cogs.commit { c in c[scores[2]] = 200 }
  #expect(cogs.peek(scores[2]) == 200)
  #expect(cogs.peek(totals["friends"]) == 40)
  #expect(runs == 2)

  cogs.commit { c in c[scores[1]] = 100 }
  #expect(cogs.peek(totals["friends"]) == 130)
  #expect(runs == 3)
}

@MainActor
@Test
func
  `GRAPH-12 a selector follows the new keyed value reference and drops the old one`()
{
  let cogs = Cogtext.forTesting()
  let currentZip = ManualCog<String>("90210")
  let weather = ManualCogBox<Int, String> { zip in
    zip == "90210" ? 72 : 41
  }
  var runs = 0

  let currentTemperature = Cog<Int> { c in
    runs += 1
    let zip = c[currentZip]
    return c[weather[zip]]
  }

  #expect(cogs.peek(currentTemperature) == 72)
  #expect(runs == 1)

  cogs.commit { c in c[currentZip] = "10001" }
  #expect(cogs.peek(currentTemperature) == 41)
  #expect(runs == 2)

  cogs.commit { c in c[weather["10001"]] = 50 }
  #expect(cogs.peek(currentTemperature) == 50)
  #expect(runs == 3)

  cogs.commit { c in c[weather["90210"]] = 99 }
  #expect(cogs.peek(weather["90210"]) == 99)
  #expect(cogs.peek(currentTemperature) == 50)
  #expect(runs == 3)
}
