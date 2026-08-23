import CogLintCore

/// Adds the declaration-shape naming corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `cog-declaration-suffix`.
  package static let cogDeclarationSuffix = CogLintRuleFixture(
    rule: CogDeclarationSuffixRule(),
    documentation: CogLintRuleDocumentation(
      violation:
        "A recognized Cog declaration must end in `Cog` for a keyless reference or `Cogs` for a keyed box.",
      rationale:
        "The suffix makes reference shape visible at every use and keeps narrower qualifiers such as `Source`, `Async`, or a domain role before the common ending. A reader can therefore distinguish a declaration from an ordinary domain value and know whether it needs a key without chasing its type.",
      repair:
        "Rename the declaration so its final word matches its shape. For example, change `weatherCogSource` to `weatherSourceCog`, and change a `CogBox.Manual` named `reportCog` to `reportCogs`."
    ),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Missing and misplaced suffixes",
          explanation:
            "A recognized declaration must finish with its shape suffix, after every narrower qualifier.",
          source:
            """
            let temperature = Cog<Int> { _ in 0 }
            let weatherCogSource = Cog.Manual(0)
            let forecastCogsAsync = Cog<String>.Async(default: "") { _ in fatalError() }
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
            let reportCog = CogBox<String, Int>.Manual(0)
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
          private let weatherServiceSourceCog = Cog.Manual(0)
          let weatherServiceCog = weatherServiceSourceCog.readOnly
          let forecastAsyncCog = Cog<String>.Async(default: "") { _ in fatalError() }
          private let weatherReportSourceCogs = CogBox<String, Int>.Manual(0)
          let weatherReportCogs = weatherReportSourceCogs.readOnly
          let forecastAsyncCogs = CogBox<String, Int>.Async(default: "") { _, _ in fatalError() }
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
          typealias Source = Cog<Int>.Manual
          let factory = makeSource()
          let alias = Source(0)
          let external = externallyDeclaredReference
          """
      )
    ]
  )
}
