import Cog
import CogTesting
import Testing

// Every assertion resolves this one declaration. Different declarations would
// make isolation vacuous: their values would differ even in one context.
@MainActor
private let one05State = ManualCog<Int>(41, name: "one05.state")

@MainActor
@Test func `ONE-05 test and preview contexts coexist without sharing state`() {
  let testContext = Cogtext.forTesting()
  let previewContext = Cogtext.forTesting()

  #expect(testContext !== previewContext)
  #expect(testContext.peek(one05State) == 41)
  #expect(previewContext.peek(one05State) == 41)

  testContext.commit("test.write") { c in c[one05State] = 101 }

  #expect(testContext.peek(one05State) == 101)
  #expect(previewContext.peek(one05State) == 41)

  previewContext.commit("preview.write") { c in c[one05State] = 202 }

  #expect(testContext.peek(one05State) == 101)
  #expect(previewContext.peek(one05State) == 202)
}

@MainActor
@Test func `ONE-05 many sequential contexts each start clean`() {
  var previous: (cogs: Cogtext, written: Int)?

  for index in 0..<50 {
    let current = Cogtext.forTesting()

    if let previous {
      #expect(current !== previous.cogs)
      #expect(previous.cogs.peek(one05State) == previous.written)
    }
    #expect(current.peek(one05State) == 41)

    let written = 1_000 + index
    current.commit("sequential.write") { c in c[one05State] = written }

    #expect(current.peek(one05State) == written)
    previous = (current, written)
  }
}

@MainActor
@Test func `ONE-05 isolated contexts never occupy or disturb the app install slot`() {
  #expect(Cogtext.hasBootstrappedApp == false)

  let beforeInstall = Cogtext.forTesting()
  #expect(beforeInstall.peek(one05State) == 41)
  #expect(Cogtext.hasBootstrappedApp == false)

  Cogtext.withBootstrappedApp { app in
    #expect(Cogtext.isBootstrappedApp(app))

    let duringInstall = Cogtext.forTesting()
    #expect(Cogtext.isBootstrappedApp(app))
    #expect(Cogtext.isBootstrappedApp(beforeInstall) == false)
    #expect(Cogtext.isBootstrappedApp(duringInstall) == false)
    #expect(app.peek(one05State) == 41)
    #expect(duringInstall.peek(one05State) == 41)

    duringInstall.commit("isolated.during-app") { c in c[one05State] = 303 }

    #expect(duringInstall.peek(one05State) == 303)
    #expect(app.peek(one05State) == 41)
    #expect(Cogtext.isBootstrappedApp(app))
  }

  #expect(Cogtext.hasBootstrappedApp == false)

  let afterInstall = Cogtext.forTesting()
  #expect(afterInstall !== beforeInstall)
  #expect(afterInstall.peek(one05State) == 41)
  #expect(Cogtext.hasBootstrappedApp == false)
}
