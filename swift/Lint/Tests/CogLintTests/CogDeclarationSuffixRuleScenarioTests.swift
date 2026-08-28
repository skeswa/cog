import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-06

/// Proves shape plurality and final qualifier placement against the shared corpus.
@Test func `LINT-06 declaration suffix fixture is the rule specification`() {
  #expect(
    CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.cogDeclarationSuffix).isEmpty
  )
}

/// Proves the registered rule emits the settled diagnostic and permanent help URL.
@Test func `LINT-06 production registry reports the shape-specific suffix`() throws {
  let execution = try lintScratchSource(
    "private let _reportCog = CogBox<String, Int>.Manual { 0 }\n",
    named: "State.swift"
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "State.swift:1:13: error: [cog-declaration-suffix] Cog declaration names must end in `Cogs` for this shape, with qualifiers before the suffix — https://skeswa.github.io/cog/documentation/cog/cogdeclarationsuffix\n"
  )
}
