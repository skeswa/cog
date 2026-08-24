import Cog
import CogTesting
import Testing

// A declaration is one descriptor shared by every state it ever names, so the
// only place a per-state value can be made is the moment a state is created.
// That is what the starting-value closure buys, and it is invisible until
// `Value` is something two holders can both mutate.

/// A mutable reference-type value, the case these scenarios exist for.
///
/// Deliberately a class: with a struct, every one of these expectations would
/// hold for a stored starting value too, and the scenario would prove nothing.
@MainActor
private final class Draft {
  var text: String = ""

  nonisolated deinit {}
}

// MARK: - DECL-13

@MainActor
@Test func `DECL-13 two contexts each get their own starting object`() {
  var closureRuns = 0
  let draftCog = Cog<Draft>.Manual {
    closureRuns += 1
    return Draft()
  }

  let first = Cogs.forTesting()
  let second = Cogs.forTesting()

  // One declaration, but the contexts are separate app runtimes, so neither
  // may hand the other something to mutate.
  first.peek(draftCog).text = "written in the first context"

  #expect(first.peek(draftCog).text == "written in the first context")
  #expect(second.peek(draftCog).text == "")
  #expect(first.peek(draftCog) !== second.peek(draftCog))
  #expect(closureRuns == 2)
}

@MainActor
@Test func `DECL-13 one context runs the starting closure once, however often it is read`() {
  var closureRuns = 0
  let draftCog = Cog<Draft>.Manual {
    closureRuns += 1
    return Draft()
  }
  let cogs = Cogs.forTesting()

  let first = cogs.peek(draftCog)
  for _ in 0..<10 {
    #expect(cogs.peek(draftCog) === first)
  }

  // Per state, not per read: a state that already exists never re-derives its
  // starting value.
  #expect(closureRuns == 1)
}

@MainActor
@Test func `DECL-13 declaring a source runs no starting closure`() {
  var closureRuns = 0
  _ = Cog<Draft>.Manual {
    closureRuns += 1
    return Draft()
  }

  // Declarations allocate a descriptor and nothing else; without a context
  // there is no state to give a starting value to.
  #expect(closureRuns == 0)
}

// MARK: - DECL-14

@MainActor
@Test func `DECL-14 two keys of one box each get their own starting object`() {
  var closureRuns = 0
  let draftCogs = CogBox<Draft, String>.Manual {
    closureRuns += 1
    return Draft()
  }
  let cogs = Cogs.forTesting()

  cogs.peek(draftCogs["one"]).text = "written under one"

  #expect(cogs.peek(draftCogs["one"]).text == "written under one")
  #expect(cogs.peek(draftCogs["two"]).text == "")
  #expect(cogs.peek(draftCogs["one"]) !== cogs.peek(draftCogs["two"]))
  #expect(closureRuns == 2)
}

@MainActor
@Test func `DECL-14 a key runs the starting closure once and reuses that object`() {
  var closureRuns = 0
  let draftCogs = CogBox<Draft, String>.Manual {
    closureRuns += 1
    return Draft()
  }
  let cogs = Cogs.forTesting()

  let first = cogs.peek(draftCogs["one"])
  for _ in 0..<10 {
    #expect(cogs.peek(draftCogs["one"]) === first)
  }
  #expect(closureRuns == 1)

  // Subscripting builds a value reference and nothing else, so naming a key
  // that has never been read still creates no state.
  _ = draftCogs["never read"]
  #expect(closureRuns == 1)
}
