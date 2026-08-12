import Cog
import CogTesting
import Testing

// The two scenarios `M1-01b` greens. Both are written against the public `Cog`
// API and the `CogTesting` product and nothing else — no `@testable`, no state
// storage, no counts of anything internal. That is scenarios.md constraint 3,
// and it has teeth: COUNT-09 through COUNT-11 require this suite to keep
// passing unchanged when the core underneath it is replaced, so a test that
// could notice how state is stored would be a test that fails a swap it should
// not care about. What is asserted here is only what a user of the library was
// promised: a declaration reads back its starting value, and a test can get a
// context by asking for one.
//
// Value references are declared inside each test rather than at file scope. A `ManualCog`
// is MainActor-isolated, and a file-scope `let` would say different things in
// the MainActor and nonisolated legs of the matrix; a local says the same
// thing in all four. Every test states `@MainActor` for the same reason (§7).

// MARK: - DECL-01

@MainActor
@Test func `DECL-01 a declared source reads back its starting value`() {
  let cogs = Cogtext.forTesting()

  let retryLimit = ManualCog<Int>(3)
  let greeting = ManualCog<String>("hello")
  let currentZip = ManualCog<String?>(nil)

  #expect(cogs.read(retryLimit) == 3)
  #expect(cogs.read(greeting) == "hello")
  #expect(cogs.read(currentZip) == nil)
}

@MainActor
@Test func `DECL-01 a source keeps returning its starting value until something writes`() {
  // Reading is not a one-time unwrapping of the declaration: with nothing
  // written, the tenth read says what the first read said.
  let cogs = Cogtext.forTesting()
  let retryLimit = ManualCog<Int>(3)

  for _ in 0..<10 {
    #expect(cogs.read(retryLimit) == 3)
  }
}

@MainActor
@Test func `DECL-01 two declarations of the same value hold their own starting values`() {
  // The starting value belongs to the declaration, not to the type or the
  // context. Two sources that look identical are still two different cogs.
  let cogs = Cogtext.forTesting()

  let attempts = ManualCog<Int>(0)
  let failures = ManualCog<Int>(0)
  let ceiling = ManualCog<Int>(5)

  #expect(cogs.read(attempts) == 0)
  #expect(cogs.read(failures) == 0)
  #expect(cogs.read(ceiling) == 5)
}

// MARK: - ONE-04

@MainActor
@Test func `ONE-04 a test gets a working context from the testing product alone`() {
  // No app bootstrap, no environment, no shared setup, no teardown: the whole
  // ceremony is one call, and the context that comes back is immediately
  // usable.
  let cogs = Cogtext.forTesting()

  let retryLimit = ManualCog<Int>(3)

  #expect(cogs.read(retryLimit) == 3)
}

@MainActor
@Test func `ONE-04 every request for a testing context gets a fresh one`() {
  // Two contexts, not one shared context handed out twice — which is what lets
  // two previews, or two tests running in parallel, each have their own world.
  let first = Cogtext.forTesting()
  let second = Cogtext.forTesting()

  #expect(first !== second)

  let retryLimit = ManualCog<Int>(3)

  #expect(first.read(retryLimit) == 3)
  #expect(second.read(retryLimit) == 3)
}

@MainActor
@Test func `ONE-04 a fresh context starts clean however many came before it`() {
  // The fiftieth context of a test run is as clean as the first. Nothing
  // accumulates in a process-global, so nothing has to be reset between tests.
  let declaration = ManualCog<Int>(3)

  for _ in 0..<50 {
    let cogs = Cogtext.forTesting()
    #expect(cogs.read(declaration) == 3)
  }
}
