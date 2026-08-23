import Cog
import CogTesting
import Testing

// Public API only. These are the first user-visible turn stories, so nothing
// here may observe phase objects, pending storage, or state layout.

// MARK: - READ-01

@MainActor
@Test func `READ-01 a read after turn sees the written value`() {
  let cogs = Cogs.forTesting()
  let count = Cog<Int>.Manual(0)

  cogs.turn { c in
    c[count] = 1
  }

  #expect(cogs.peek(count) == 1)
}
