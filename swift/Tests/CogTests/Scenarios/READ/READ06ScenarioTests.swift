import Cog
import CogTesting
import Testing

@MainActor
@Test func `READ-06 a trigger rerun peeks at the newest settled value`() {
  let cogs = Cogs.forTesting()
  let trigger = ManualCog<Int>(0)
  let xSource = ManualCog<Int>(1)
  var xRuns = 0
  var selectorRuns = 0

  let x = Cog<Int> { c in
    xRuns += 1
    return c[xSource] * 2
  }
  let snapshot = Cog<String> { c in
    selectorRuns += 1
    return "\(c[trigger]):\(c.peek(x))"
  }

  #expect(cogs.peek(snapshot) == "0:2")
  #expect((selectorRuns, xRuns) == (1, 1))

  cogs.commit { c in c[xSource] = 2 }
  #expect(cogs.peek(xSource) == 2)
  #expect(cogs.peek(snapshot) == "0:2")
  #expect((selectorRuns, xRuns) == (1, 1))

  cogs.commit { c in c[trigger] = 1 }
  #expect(cogs.peek(snapshot) == "1:4")
  #expect((selectorRuns, xRuns) == (2, 2))
}

@MainActor
@Test func `READ-06 manual and read-only peeks also skip edges`() {
  let cogs = Cogs.forTesting()
  let trigger = ManualCog<Int>(0)
  let manual = ManualCog<Int>(1)
  let owned = ManualCog<Int>(10)
  let exposed = owned.readOnly
  var snapshots: [String] = []

  let snapshot = Cog<String> { c in
    let value = "\(c[trigger]):\(c.peek(manual)):\(c.peek(exposed))"
    snapshots.append(value)
    return value
  }

  #expect(cogs.peek(snapshot) == "0:1:10")
  #expect(snapshots == ["0:1:10"])

  cogs.commit { c in
    c[manual] = 2
    c[owned] = 20
  }
  #expect(cogs.peek(manual) == 2)
  #expect(cogs.peek(exposed) == 20)
  #expect(cogs.peek(snapshot) == "0:1:10")
  #expect(snapshots == ["0:1:10"])

  cogs.commit { c in c[trigger] = 1 }
  #expect(cogs.peek(snapshot) == "1:2:20")
  #expect(snapshots == ["0:1:10", "1:2:20"])
}
