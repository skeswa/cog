import CogLintCore

/// Adds the assembly-only initial-state corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `initial-state-in-mechanism`.
  package static let initialStateInMechanism = CogLintRuleFixture(
    rule: InitialStateInMechanismRule(),
    documentation: CogLintRuleDocumentation(
      violation:
        "An app initializer uses a local returned directly by `Cogs.assemble` for graph work instead of only retaining it.",
      rationale:
        "An assembly mechanism's `operate` runs inside assembly, so its writes settle before `assemble` returns and before any watcher can observe the initial value on the way past. Entry-point graph work would expose an intermediate world and split production initialization from the mechanism arrangement tests can reproduce.",
      repair:
        "Move initial reads, named operations, and primitive calls into a `Mechanism` supplied to `assemble(mechanisms:)`. The app initializer may construct services and mechanisms, assemble once, and retain the returned runtime directly."
    ),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Graph work around retention",
          explanation:
            "A directly assembled local cannot perform named operations, reads, helpers, or primitives.",
          source:
            """
            struct WeatherApp: App {
              @State private var cogs: Cogs
              init() {
                let cogs = Cogs.assemble(mechanisms: [])
                cogs.selectCurrentLocation(.newYork)
                _ = cogs[currentZipCodeCog]
                helper(cogs)
                _cogs = State(initialValue: cogs)
                cogs.turn(_currentZipCog, to: .newYork)
                cogs.refresh(forecastCog)
              }
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 5, column: 5),
          CogLintFixturePosition(line: 6, column: 9),
          CogLintFixturePosition(line: 7, column: 12),
          CogLintFixturePosition(line: 9, column: 5),
          CogLintFixturePosition(line: 10, column: 5),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Indirect retention value",
          explanation:
            "Retention must consume the assembly result directly instead of hiding graph work in a helper.",
          source:
            """
            struct WeatherApp: App {
              @State private var cogs: Cogs
              init() {
                let graph = Cogs.assemble()
                _cogs = State(initialValue: prepare(graph))
              }
            }
            """
        ),
        positions: [CogLintFixturePosition(line: 5, column: 41)]
      ),
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "Services and mechanisms before local retention",
        explanation:
          "Ordinary construction may precede assembly, whose local result goes directly into `State`.",
        source:
          """
          struct WeatherApp: App {
            @State private var cogs: Cogs
            init() {
              let notifier = Notifier.live
              let mechanism = WeatherMechanism(notifier: notifier)
              let cogs = Cogs.assemble(mechanisms: [mechanism])
              _cogs = SwiftUI.State<Cogs>(initialValue: cogs)
            }
          }
          """
      ),
      CogLintFixtureExample(
        name: "Direct assembly retention",
        explanation:
          "Assigning the assembly expression directly leaves no local on which to perform work.",
        source:
          """
          struct PlainApp: App {
            private let cogs: Cogs
            init() { self.cogs = Cogs.assemble(mechanisms: []) }
          }
          struct WrappedApp: App {
            @State private var cogs: Cogs
            init() { _cogs = State(initialValue: Cogs.assemble()) }
          }
          """
      ),
      CogLintFixtureExample(
        name: "Plain property retention from a local",
        explanation:
          "A local may be assigned directly to the app runtime property without intervening work.",
        source:
          """
          struct PlainApp: App {
            private let cogs: Cogs
            init() {
              let graph = Cogs.assemble()
              self.cogs = graph
            }
          }
          """
      ),
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Factory-hidden assembly and cross-file app identity",
        explanation:
          "A factory-hidden runtime and a type whose `App` conformance lives elsewhere remain syntax-only misses.",
        source:
          """
          struct FactoryApp: App {
            init() {
              let cogs = makeAppGraph()
              cogs.selectCurrentLocation(.newYork)
            }
          }
          struct CrossFileApp {
            init() {
              let cogs = Cogs.assemble()
              cogs.selectCurrentLocation(.newYork)
            }
          }
          """
      )
    ]
  )
}
