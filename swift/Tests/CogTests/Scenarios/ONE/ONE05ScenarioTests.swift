import Cog
import CogTesting
import Testing

// Every assertion resolves this one declaration. Different declarations would
// make isolation vacuous: their values would differ even in one context.
@MainActor
private let _one05StateCog = Cog<Int>.Manual({ 41 }, name: "one05.state")

@MainActor
@Test func `ONE-05 test and preview contexts coexist without sharing state`() {
  let testContext = Cogs.forTesting()
  let previewContext = Cogs.forTesting()

  #expect(testContext !== previewContext)
  #expect(testContext.peek(_one05StateCog) == 41)
  #expect(previewContext.peek(_one05StateCog) == 41)

  testContext.turn("test.write") { c in c[_one05StateCog] = 101 }

  #expect(testContext.peek(_one05StateCog) == 101)
  #expect(previewContext.peek(_one05StateCog) == 41)

  previewContext.turn("preview.write") { c in c[_one05StateCog] = 202 }

  #expect(testContext.peek(_one05StateCog) == 101)
  #expect(previewContext.peek(_one05StateCog) == 202)
}

@MainActor
@Test func `ONE-05 many sequential contexts each start clean`() {
  var previous: (cogs: Cogs, written: Int)?

  for index in 0..<50 {
    let current = Cogs.forTesting()

    if let previous {
      #expect(current !== previous.cogs)
      #expect(previous.cogs.peek(_one05StateCog) == previous.written)
    }
    #expect(current.peek(_one05StateCog) == 41)

    let written = 1_000 + index
    current.turn("sequential.write") { c in c[_one05StateCog] = written }

    #expect(current.peek(_one05StateCog) == written)
    previous = (current, written)
  }
}

@MainActor
@Test func `ONE-05 isolated contexts never occupy or disturb the app install slot`() {
  #expect(Cogs.hasAssembledCogs == false)

  let beforeInstall = Cogs.forTesting()
  #expect(beforeInstall.peek(_one05StateCog) == 41)
  #expect(Cogs.hasAssembledCogs == false)

  Cogs.withAssembledCogs { app in
    #expect(Cogs.isAssembledCogs(app))

    let duringInstall = Cogs.forTesting()
    #expect(Cogs.isAssembledCogs(app))
    #expect(Cogs.isAssembledCogs(beforeInstall) == false)
    #expect(Cogs.isAssembledCogs(duringInstall) == false)
    #expect(app.peek(_one05StateCog) == 41)
    #expect(duringInstall.peek(_one05StateCog) == 41)

    duringInstall.turn("isolated.during-app") { c in c[_one05StateCog] = 303 }

    #expect(duringInstall.peek(_one05StateCog) == 303)
    #expect(app.peek(_one05StateCog) == 41)
    #expect(Cogs.isAssembledCogs(app))
  }

  #expect(Cogs.hasAssembledCogs == false)

  let afterInstall = Cogs.forTesting()
  #expect(afterInstall !== beforeInstall)
  #expect(afterInstall.peek(_one05StateCog) == 41)
  #expect(Cogs.hasAssembledCogs == false)
}
