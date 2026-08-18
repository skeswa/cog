import CogLintCore

/// Adds the bootstrap-only initial-state corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `initial-state-in-mechanism`.
  package static let initialStateInMechanism = CogLintRuleFixture(
    rule: InitialStateInMechanismRule(),
    documentation: CogLintRuleDocumentation(
      violation:
        "An app initializer uses a local returned directly by `Cogs.bootstrapApp` for graph work instead of only retaining it.",
      rationale:
        "A bootstrap mechanism's `operate` runs inside bootstrap, so its writes settle before `bootstrapApp` returns and before any watcher can observe the initial value on the way past. Entry-point graph work would expose an intermediate world and split production initialization from the mechanism arrangement tests can reproduce.",
      repair:
        "Move initial reads, named operations, and primitive calls into a `Mechanism` supplied to `bootstrapApp(mechanisms:)`. The app initializer may construct services and mechanisms, bootstrap once, and retain the returned runtime directly."
    ),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Graph work around retention",
          explanation:
            "A directly bootstrapped local cannot perform named operations, reads, helpers, or primitives.",
          source:
            """
            struct WeatherApp: App {
              @State private var cogs: Cogs
              init() {
                let cogs = Cogs.bootstrapApp(mechanisms: [])
                cogs.selectCurrentLocation(.newYork)
                _ = cogs[currentZipCodeCog]
                helper(cogs)
                _cogs = State(initialValue: cogs)
                cogs.commit(currentZipSourceCog, to: .newYork)
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
            "Retention must consume the bootstrap result directly instead of hiding graph work in a helper.",
          source:
            """
            struct WeatherApp: App {
              @State private var cogs: Cogs
              init() {
                let graph = Cogs.bootstrapApp()
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
          "Ordinary construction may precede bootstrap, whose local result goes directly into `State`.",
        source:
          """
          struct WeatherApp: App {
            @State private var cogs: Cogs
            init() {
              let notifier = Notifier.live
              let mechanism = WeatherMechanism(notifier: notifier)
              let cogs = Cogs.bootstrapApp(mechanisms: [mechanism])
              _cogs = SwiftUI.State<Cogs>(initialValue: cogs)
            }
          }
          """
      ),
      CogLintFixtureExample(
        name: "Direct bootstrap retention",
        explanation:
          "Assigning the bootstrap expression directly leaves no local on which to perform work.",
        source:
          """
          struct PlainApp: App {
            private let cogs: Cogs
            init() { self.cogs = Cogs.bootstrapApp(mechanisms: []) }
          }
          struct WrappedApp: App {
            @State private var cogs: Cogs
            init() { _cogs = State(initialValue: Cogs.bootstrapApp()) }
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
              let graph = Cogs.bootstrapApp()
              self.cogs = graph
            }
          }
          """
      ),
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Factory-hidden bootstrap and cross-file app identity",
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
              let cogs = Cogs.bootstrapApp()
              cogs.selectCurrentLocation(.newYork)
            }
          }
          """
      )
    ]
  )
}
