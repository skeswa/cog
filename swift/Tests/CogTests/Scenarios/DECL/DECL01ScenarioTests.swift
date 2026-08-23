import Cog
import CogTesting
import Testing

// MARK: - DECL-01

@MainActor
@Test func `DECL-01 a declared source reads back its starting value`() {
  let cogs = Cogs.forTesting()

  let retryLimit = Cog<Int>.Manual(3)
  let greeting = Cog<String>.Manual("hello")
  let currentZip = Cog<String?>.Manual(nil)

  #expect(cogs.peek(retryLimit) == 3)
  #expect(cogs.peek(greeting) == "hello")
  #expect(cogs.peek(currentZip) == nil)
}

@MainActor
@Test func `DECL-01 a source keeps returning its starting value until something writes`() {
  // Reading is not a one-time unwrapping of the declaration: with nothing
  // written, the tenth read says what the first read said.
  let cogs = Cogs.forTesting()
  let retryLimit = Cog<Int>.Manual(3)

  for _ in 0..<10 {
    #expect(cogs.peek(retryLimit) == 3)
  }
}
