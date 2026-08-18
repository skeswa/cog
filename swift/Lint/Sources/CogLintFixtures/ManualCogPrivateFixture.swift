import CogLintCore

/// Adds the first production rule corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `manual-cog-private`.
  package static let manualCogPrivate = CogLintRuleFixture(
    rule: ManualCogPrivateRule(),
    documentation: CogLintRuleDocumentation(
      violation:
        "A recognized `ManualCog` or `ManualCogBox` source has wider access than `private` or `fileprivate`.",
      rationale:
        "Cog state is singular, so each mutable fact has one writable source owned by the file that defines it. Exporting the manual declaration exports a writer target and lets unrelated code bypass the named domain operations that explain who may change that fact.",
      repair:
        "Narrow the writable source to `private` or `fileprivate`. When another file needs to read it, expose the source's `.readOnly` projection or a genuinely derived cog instead of the manual declaration itself."
    ),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Implicit internal access",
          explanation: "A bare source declaration is internal and exposes a writer target.",
          source: "let countSourceCog = ManualCog(0)\n"
        ),
        positions: [CogLintFixturePosition(line: 1, column: 5)]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Explicit wider access",
          explanation:
            "Internal, package, and public source names all cross the owning file boundary.",
          source:
            """
            internal let retrySourceCog: Cog.ManualCog<Int> = .init(0)
            package let reportSourceCogs = ManualCogBox<String?, Int>(nil)
            public let sessionSourceCog = ManualCog("")
            """
        ),
        positions: [
          CogLintFixturePosition(line: 1, column: 14),
          CogLintFixturePosition(line: 2, column: 13),
          CogLintFixturePosition(line: 3, column: 12),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Setter-only privacy",
          explanation: "`private(set)` leaves the source name visible at its wider read access.",
          source: "public private(set) var sessionSourceCog = ManualCog(\"\")\n"
        ),
        positions: [CogLintFixturePosition(line: 1, column: 25)]
      ),
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "File-owned sources and public reads",
        explanation:
          "Bare private access owns writer targets, while derived and read-only names may remain wider.",
        source:
          """
          private let countSourceCog = ManualCog(0)
          fileprivate let reportSourceCogs = ManualCogBox<String?, Int>(nil)
          let countCog = countSourceCog.readOnly
          let doubledCog = Cog<Int> { c in c[countCog] * 2 }
          """
      )
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Syntax-hidden source identity",
        explanation:
          "Factories, typealiases, and the sanctioned seed re-export do not spell a new manual declaration.",
        source:
          """
          typealias Source = ManualCog<Int>
          private let countSourceCog = ManualCog(0)
          let factorySourceCog = makeSource()
          let aliasSourceCog = Source(0)
          #if DEBUG
          let countSeedTargetCog = countSourceCog
          #endif
          """
      )
    ]
  )
}
