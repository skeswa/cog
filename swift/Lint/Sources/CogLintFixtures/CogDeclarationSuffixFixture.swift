import CogLintCore

/// Adds the declaration-shape naming corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `cog-declaration-suffix`.
  package static let cogDeclarationSuffix = CogLintRuleFixture(
    rule: CogDeclarationSuffixRule(),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Missing and misplaced suffixes",
          explanation:
            "A recognized declaration must finish with its shape suffix, after every narrower qualifier.",
          source:
            """
            let temperature = Cog<Int> { _ in 0 }
            let weatherCogSource = ManualCog(0)
            let forecastCogsAsync = AsyncCog<String> { _ in "" }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 1, column: 5),
          CogLintFixturePosition(line: 2, column: 5),
          CogLintFixturePosition(line: 3, column: 5),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Wrong shape plurality",
          explanation: "Keyless references use singular `Cog`; boxes use plural `Cogs`.",
          source:
            """
            let selectedCogs = Cog<Int> { _ in 0 }
            let reportCog = ManualCogBox<String, Int>(0)
            let avatarCog: CogBox<String, Data> = .init { _ in Data() }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 1, column: 5),
          CogLintFixturePosition(line: 2, column: 5),
          CogLintFixturePosition(line: 3, column: 5),
        ]
      ),
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "Shape suffixes after qualifiers",
        explanation:
          "Keyless and boxed declarations end in their singular or plural suffix after role qualifiers.",
        source:
          """
          let temperatureCog = Cog<Int> { _ in 0 }
          private let weatherServiceSourceCog = ManualCog(0)
          let weatherServiceCog = weatherServiceSourceCog.readOnly
          let forecastAsyncCog = AsyncCog<String> { _ in "" }
          private let weatherReportSourceCogs = ManualCogBox<String, Int>(0)
          let weatherReportCogs = weatherReportSourceCogs.readOnly
          let forecastAsyncCogs = AsyncCogBox<String, Int> { _ in 0 }
          """
      )
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Syntax-hidden declaration shape",
        explanation:
          "Factories, typealiases, and cross-file identity remain outside the shared syntax-only classifier.",
        source:
          """
          typealias Source = ManualCog<Int>
          let factory = makeSource()
          let alias = Source(0)
          let external = externallyDeclaredReference
          """
      )
    ]
  )
}
