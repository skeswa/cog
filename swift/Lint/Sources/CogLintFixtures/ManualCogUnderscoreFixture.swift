import CogLintCore

/// Adds the underscored-source naming corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `manual-cog-underscore`.
  package static let manualCogUnderscore = CogLintRuleFixture(
    rule: ManualCogUnderscoreRule(),
    documentation: CogLintRuleDocumentation(
      violation:
        "A recognized `Cog.Manual` or `CogBox.Manual` declaration name lacks its leading underscore, or a `.readOnly` projection is not named exactly its source's name without the underscore.",
      rationale:
        "The published projection is the name the rest of the app reads, so it owns the clean domain spelling, and the leading underscore marks the file-owned writable source beside it. Pairing the two names exactly keeps one fact's source and published reference recognizable as one pair at a glance, instead of letting a tweaked source qualifier drift away from the name every call site uses.",
      repair:
        "Prefix the manual declaration with `_` and name its `.readOnly` projection the same identifier without the underscore: `private let _countCog = Cog.Manual(0)` published as `let countCog = _countCog.readOnly`."
    ),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Sources without the leading underscore",
          explanation:
            "Keyless and boxed manual declarations must both begin with `_`.",
          source:
            """
            private let countCog = Cog.Manual(0)
            private let reportCogs = CogBox<String?, Int>.Manual(nil)
            """
        ),
        positions: [
          CogLintFixturePosition(line: 1, column: 13),
          CogLintFixturePosition(line: 2, column: 13),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Retired Source qualifier pair",
          explanation:
            "The former `Source` spelling violates both halves: the source lacks its underscore and the projection no longer matches it.",
          source:
            """
            private let countSourceCog = Cog.Manual(0)
            let countCog = countSourceCog.readOnly
            """
        ),
        positions: [
          CogLintFixturePosition(line: 1, column: 13),
          CogLintFixturePosition(line: 2, column: 5),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Renamed projection",
          explanation:
            "A projection may not publish a different domain name than its source states.",
          source:
            """
            private let _countCog = Cog.Manual(0)
            let totalCog = _countCog.readOnly
            """
        ),
        positions: [CogLintFixturePosition(line: 2, column: 5)]
      ),
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "Underscored sources and exactly paired projections",
        explanation:
          "Each projection drops exactly the underscore, and an unprojected underscored source is accepted.",
        source:
          """
          private let _countCog = Cog.Manual(0)
          let countCog = _countCog.readOnly
          private let _reportCogs = CogBox<String?, Int>.Manual(nil)
          let reportCogs = _reportCogs.readOnly
          private let _draftCog = Cog.Manual("")
          """
      )
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Syntax-hidden source identity",
        explanation:
          "Aliases, factories, and copies stay outside the syntax-only classifier, so a projection of a copied source cannot be paired.",
        source:
          """
          typealias Source = Cog<Int>.Manual
          let aliasCog = Source(0)
          let factoryCog = makeSource()
          private let _countCog = Cog.Manual(0)
          let copiedCog = _countCog
          let renamedCog = copiedCog.readOnly
          """
      )
    ]
  )
}
