import Cog
import CogTesting
import Testing

// Public API only. These are the first user-visible turn stories, so nothing
// here may observe phase objects, pending storage, or node layout.

@MainActor
@Test func `READ-01 a read after commit sees the written value`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)

  cogs.commit { w in
    w[count] = 1
  }

  #expect(cogs.read(count) == 1)
}

@MainActor
@Test func `TURN-01 the writer reads back the value it staged`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)

  cogs.commit { w in
    w[count] = 4
    #expect(w[count] == 4)

    w[count] += 1
    #expect(w[count] == 5)
  }

  #expect(cogs.read(count) == 5)
}

@MainActor
@Test func `TURN-02 the last repeated write is the one downstream sees`() {
  var sourceValuesSeen: [Int] = []

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  let doubled = Cog<Int> { c in
    let value = c.get(source)
    sourceValuesSeen.append(value)
    return value * 2
  }

  #expect(cogs.read(doubled) == 0)

  cogs.commit { w in
    w[source] = 1
    #expect(w[source] == 1)

    w[source] = 2
    #expect(w[source] == 2)
  }

  #expect(cogs.read(doubled) == 4)
  #expect(sourceValuesSeen == [0, 2])
}

@MainActor
@Test func `TURN-03 the writer reads current state before staging that source`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)
  let note = ManualCog<String>("old")

  cogs.commit { w in
    w[count] = 3
  }

  cogs.commit { w in
    w[note] = "new"
    #expect(w[count] == 3)
  }
}

@MainActor
@Test func `TURN-04 normal reads stay committed while the writer accumulates`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)

  cogs.commit { w in
    w[count] = 7

    #expect(w[count] == 7)
    #expect(cogs.read(count) == 0)
  }

  #expect(cogs.read(count) == 7)
}

@MainActor
@Test func `TURN-14 keyed writer read-back changes only the selected key`() {
  let cogs = Cogtext.forTesting()
  let unreadCounts = ManualCogBox<Int, String>(0)

  cogs.commit { w in
    w[unreadCounts["inbox"]] += 1

    #expect(w[unreadCounts["inbox"]] == 1)
    #expect(w[unreadCounts["archive"]] == 0)
  }

  #expect(cogs.read(unreadCounts["inbox"]) == 1)
  #expect(cogs.read(unreadCounts["archive"]) == 0)
}
