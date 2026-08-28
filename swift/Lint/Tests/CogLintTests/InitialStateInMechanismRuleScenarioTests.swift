import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-10

/// Proves forbidden assembly-local work before and after retention.
@Test func `LINT-10 assembly local fixture is the rule specification`() {
  #expect(
    CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.initialStateInMechanism).isEmpty
  )
}

/// Proves the production registry diagnoses a correctly wrapped but misplaced domain op.
@Test func `LINT-10 production registry reports assembly-local domain work`() throws {
  let execution = try lintScratchSource(
    "struct MainApp: App { init() { let cogs = Cogs.assemble(); cogs.seedWorld() } }\n",
    named: "MainApp.swift"
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "MainApp.swift:1:60: error: [initial-state-in-mechanism] `cogs` may only retain the result of `Cogs.assemble`; move initial graph work into an assembly mechanism — https://skeswa.github.io/cog/documentation/cog/initialstateinmechanism\n"
  )
}

// MARK: - LINT-11

/// Proves both settled direct-retention spellings remain conforming.
@Test func `LINT-11 direct assembly retention needs no local analysis`() {
  let source = CogLintParser.parse(
    source:
      """
      struct DirectApp: App {
        private let cogs: Cogs
        init() { cogs = Cogs.assemble() }
      }
      struct WrappedApp: App {
        @State private var cogs: Cogs
        init() { _cogs = .init(initialValue: Cogs.assemble()) }
      }
      """
  )
  let context = CogLintRuleContext(targetRole: .production)
  #expect(InitialStateInMechanismRule().violations(in: source, context: context).isEmpty)
}
