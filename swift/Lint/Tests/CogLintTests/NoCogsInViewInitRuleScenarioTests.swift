import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-07

/// Proves view storage and parameter boundaries against the shared corpus.
@Test func `LINT-07 view graph boundary fixture is the rule specification`() {
  #expect(CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.noCogsInViewInit).isEmpty)
}

/// Proves the registered rule emits its environment-focused repair guidance.
@Test func `LINT-07 production registry reports a view initializer parameter`() throws {
  let execution = try lintScratchSource(
    "struct Panel: View { init(cogs: Cogs) {} }\n",
    named: "Panel.swift"
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "Panel.swift:1:33: error: [no-cogs-in-view-init] views must resolve `Cogs` with `@Environment(\\.cogs)`, not store or accept it — https://skeswa.github.io/cog/documentation/cog/nocogsinviewinit\n"
  )
}
