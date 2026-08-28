import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-24

/// Proves the naming rule against its shared fixture positions and evasions.
@Test func `LINT-24 underscored source naming fixture is the rule specification`() {
  #expect(
    CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.manualCogUnderscore).isEmpty
  )
}

/// Proves the registered engine emits the settled slug, message, URL, and failing status.
@Test func `LINT-24 production registry reports a source without its underscore`() throws {
  let execution = try lintScratchSource(
    "private let countCog = Cog.Manual { 0 }\n",
    named: "State.swift"
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "State.swift:1:13: error: [manual-cog-underscore] manual Cog declaration names must begin with `_`; publish the readable name as its `.readOnly` projection — https://skeswa.github.io/cog/documentation/cog/manualcogunderscore\n"
  )
}
