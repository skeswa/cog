import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-13

/// Proves exact member-level read counting against the shared corpus.
@Test func `LINT-13 multi-read helper fixture is the rule specification`() {
  #expect(
    CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.noMultiReadCogsHelper).isEmpty
  )
}

/// Proves the production registry reports the helper rather than each constituent read.
@Test func `LINT-13 production registry reports one member diagnostic`() throws {
  let execution = try lintScratchSource(
    "extension Cogs { func pair() -> Pair { Pair(self[firstCog], self[secondCog]) } }\n",
    named: "Projection.swift"
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "Projection.swift:1:23: error: [no-multi-read-cogs-helper] value-returning `Cogs` and `CogOps` helpers may contain at most one immediate graph read; read values flatly at the consumer — https://skeswa.github.io/cog/documentation/cog/nomultireadcogshelper\n"
  )
}

// MARK: - LINT-14

/// Proves reads nested in closures do not contribute to the immediate lexical count.
@Test func `LINT-14 nested closure reads are excluded`() {
  let source = CogLintParser.parse(
    source:
      """
      extension Cogs {
        func deferred() -> () -> Pair {
          { Pair(self[firstCog], self[secondCog]) }
        }
      }
      """
  )
  let context = CogLintRuleContext(targetRole: .production)
  #expect(NoMultiReadCogsHelperRule().violations(in: source, context: context).isEmpty)
}
