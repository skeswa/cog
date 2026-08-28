import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-12

/// Proves the production rule against its shared fixture positions and evasions.
@Test func `LINT-12 manual source privacy fixture is the rule specification`() {
  #expect(
    CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.manualCogPrivate).isEmpty
  )
}

/// Proves the registered engine emits the settled slug, message, URL, and failing status.
@Test func `LINT-12 production registry reports a wider manual source`() throws {
  let execution = try lintScratchSource(
    "let _countCog = Cog.Manual { 0 }\n",
    named: "State.swift"
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "State.swift:1:5: error: [manual-cog-private] writable Cog sources must be `private` or `fileprivate`; expose `.readOnly` or an automatic cog — https://skeswa.github.io/cog/documentation/cog/manualcogprivate\n"
  )
}
