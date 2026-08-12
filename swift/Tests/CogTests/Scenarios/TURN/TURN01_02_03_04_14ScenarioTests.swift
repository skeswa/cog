import Cog
import CogTesting
import Testing

// Public API only. These are the first user-visible turn stories, so nothing
// here may observe phase objects, pending storage, or state layout.

// MARK: - TURN-01 through TURN-04 and TURN-14

@MainActor
@Test func `TURN-01 the writer reads back the value it staged`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)

  cogs.commit { c in
    c[count] = 4
    #expect(c[count] == 4)

    c[count] += 1
    #expect(c[count] == 5)
  }

  #expect(cogs.peek(count) == 5)
}

@MainActor
@Test func `TURN-02 the last repeated write is the one downstream sees`() {
  var sourceValuesSeen: [Int] = []

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  let doubled = Cog<Int> { c in
    let value = c[source]
    sourceValuesSeen.append(value)
    return value * 2
  }

  #expect(cogs.peek(doubled) == 0)

  cogs.commit { c in
    c[source] = 1
    #expect(c[source] == 1)

    c[source] = 2
    #expect(c[source] == 2)
  }

  #expect(cogs.peek(doubled) == 4)
  #expect(sourceValuesSeen == [0, 2])
}

@MainActor
@Test func `TURN-03 the writer reads current state before staging that source`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)
  let note = ManualCog<String>("old")

  cogs.commit { c in
    c[count] = 3
  }

  cogs.commit { c in
    c[note] = "new"
    #expect(c[count] == 3)
  }
}

@MainActor
@Test func `TURN-04 normal reads stay committed while the writer accumulates`() {
  let cogs = Cogtext.forTesting()
  let count = ManualCog<Int>(0)

  cogs.commit { c in
    c[count] = 7

    #expect(c[count] == 7)
    #expect(cogs.peek(count) == 0)
  }

  #expect(cogs.peek(count) == 7)
}

@MainActor
@Test func `TURN-14 keyed writer read-back changes only the selected key`() {
  let cogs = Cogtext.forTesting()
  let unreadCounts = ManualCogBox<Int, String>(0)

  cogs.commit { c in
    c[unreadCounts["inbox"]] += 1

    #expect(c[unreadCounts["inbox"]] == 1)
    #expect(c[unreadCounts["archive"]] == 0)
  }

  #expect(cogs.peek(unreadCounts["inbox"]) == 1)
  #expect(cogs.peek(unreadCounts["archive"]) == 0)
}
