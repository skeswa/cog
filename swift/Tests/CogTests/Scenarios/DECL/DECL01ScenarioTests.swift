import Cog
import CogTesting
import Testing

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
