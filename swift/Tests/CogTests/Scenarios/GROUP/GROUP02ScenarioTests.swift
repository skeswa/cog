import Cog
import Testing

@MainActor
@Test func `GROUP-02 cancellation propagates to owned and later tasks`() async {
  let group = EffectGroup()
  let copy = group

  let ownedTask = group.task(name: "group.owned") {
    try await Task.sleep(for: .seconds(60))
  }

  copy.cancel()
  #expect(ownedTask.isCancelled)

  var firstRan = false
  let firstLaterTask = group.task(name: "group.afterCancel.first") {
    firstRan = true
  }
  #expect(firstLaterTask.isCancelled)

  var secondRan = false
  let secondLaterTask = copy.task(name: "group.afterCancel.second") {
    secondRan = true
  }
  #expect(secondLaterTask.isCancelled)

  await Task.yield()
  #expect(!firstRan)
  #expect(!secondRan)
}
