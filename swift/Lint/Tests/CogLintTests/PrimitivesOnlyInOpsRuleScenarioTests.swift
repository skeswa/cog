import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-08

/// Proves classified receivers and runtime extensions against the shared corpus.
@Test func `LINT-08 primitive boundary fixture is the rule specification`() {
  #expect(CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.primitivesOnlyInOps).isEmpty)
}

/// Proves the production registry reports the exact primitive and repair boundary.
@Test func `LINT-08 production registry reports an environment primitive`() throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "coglint-primitive-op-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try "struct Card: View { @Environment(\\.cogs) var cogs; func tap() { cogs.refresh(itemCog) } }\n"
    .write(
      to: root.appending(path: "Card.swift"),
      atomically: true,
      encoding: .utf8
    )

  let execution = try CogLintEngine.lint(
    paths: ["Card.swift"],
    relativeTo: root,
    targetRole: .production,
    rules: CogLintRuleRegistry.all
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "Card.swift:1:70: error: [primitives-only-in-ops] `refresh` may be called only bare inside `extension CogOps`; wrap it in a named domain op — https://skeswa.github.io/cog/documentation/cog/primitivesonlyinops\n"
  )
}

// MARK: - LINT-09

/// Proves explicit test-target configuration permits direct primitive driving.
@Test func `LINT-09 test target role exempts direct graph primitives`() {
  let source = CogLintParser.parse(
    source:
      """
      func drive(_ c: Writer) {
        c.commit(named: "test") { _ in }
        c.refresh(forecastCog)
      }
      """
  )
  let context = CogLintRuleContext(targetRole: .test)
  #expect(PrimitivesOnlyInOpsRule().violations(in: source, context: context).isEmpty)
}

/// Proves nested bare writer work remains legal throughout a `CogOps` extension.
@Test func `LINT-09 nested bare primitives remain legal inside CogOps`() {
  let source = CogLintParser.parse(
    source:
      """
      extension CogOps {
        func update() {
          commit { c in
            c[countSourceCog] = 1
            helper { commit(otherSourceCog, to: 2) }
          }
        }
      }
      """
  )
  let context = CogLintRuleContext(targetRole: .production)
  #expect(PrimitivesOnlyInOpsRule().violations(in: source, context: context).isEmpty)
}
