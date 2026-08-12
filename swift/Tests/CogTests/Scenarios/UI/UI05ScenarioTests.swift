import CogTesting
import Testing

@testable import Cog

@MainActor
@Test func `UI-05 only states read through the UI boundary allocate boundary objects`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(2)
  let interior = Cog<Int> { c in c[source] * 3 }
  let displayed = Cog<String> { c in "value: \(c[interior])" }

  #expect(cogs[displayed] == "value: 6")

  let sourceState = cogs.manualState(for: source)
  let interiorState = cogs.derivedState(for: interior)
  let displayedState = cogs.derivedState(for: displayed)

  #expect(displayedState.observationBoundary != nil)
  #expect(interiorState.observationBoundary == nil)
  #expect(sourceState.observationBoundary == nil)
  #expect(cogs.observationStates.count == 1)
  #expect(cogs.observationStates[0] === displayedState)

  #expect(cogs[source] == 2)
  #expect(sourceState.observationBoundary != nil)
  #expect(interiorState.observationBoundary == nil)
  #expect(cogs.observationStates.count == 2)
  #expect(cogs.observationStates[1] === sourceState)
}
