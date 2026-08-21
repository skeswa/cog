import CogLintCore

/// Adds the flat graph-read corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `no-multi-read-cogs-helper`.
  package static let noMultiReadCogsHelper = CogLintRuleFixture(
    rule: NoMultiReadCogsHelperRule(),
    documentation: CogLintRuleDocumentation(
      violation:
        "A value-returning member of `extension Cogs` or `extension CogOps` contains two or more immediate graph reads.",
      rationale:
        "Reads in one consumer already come from one settled turn and register independently for precise invalidation. Repackaging several reads behind a runtime helper hides the consumer's dependencies, invites the projection to be stored or forwarded, and adds a type without improving consistency.",
      repair:
        "Read each value flatly on its own line at the consuming boundary. If the combined value is genuinely automatic state rather than values merely used together, declare an automatic cog and read that single declaration instead."
    ),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Value and status repackaging",
          explanation:
            "A value helper cannot hide two direct tracked reads behind one returned projection.",
          source:
            """
            extension Cogs {
              func weatherCardReading(for zip: Zip) -> WeatherCardReading {
                let forecast = self[weatherForecastCogs[zip]]
                let selection = self[currentZipCodeCog]
                return WeatherCardReading(forecast: forecast, selection: selection)
              }
              var currentForecast: ForecastSummary {
                let forecast = status[forecastCog]
                let place = self.status[placeCog]
                return ForecastSummary(forecast: forecast, place: place)
              }
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 2, column: 8),
          CogLintFixturePosition(line: 7, column: 7),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Peek helpers on both operation capabilities",
          explanation: "Bare, self-qualified, and status peeks are direct graph reads by spelling.",
          source:
            """
            extension CogOps {
              func pair() -> Pair {
                Pair(first: peek(firstCog), second: self.peek(secondCog))
              }
            }
            extension Cogs {
              subscript(snapshot key: Key) -> Snapshot {
                get { Snapshot(value: peek(valuesCogs[key]), status: status.peek(statusCogs[key])) }
              }
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 2, column: 8),
          CogLintFixturePosition(line: 7, column: 3),
        ]
      ),
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "One direct read per value helper",
        explanation:
          "A narrow helper exposing one graph read does not repackage several dependencies.",
        source:
          """
          extension Cogs {
            func selectedZip() -> Zip? { peek(selectedZipCog) }
            var currentCount: Int { self[countCog] }
          }
          """
      ),
      CogLintFixtureExample(
        name: "Excluded member returns and nested closures",
        explanation:
          "Void, view, binding, and closure-contained reads stay outside the exact value-helper rule.",
        source:
          """
          extension Cogs {
            func inspect() { _ = self[firstCog]; _ = self[secondCog] }
            func reset() -> Void { _ = peek(firstCog); _ = peek(secondCog) }
            func clear() -> () { _ = status[firstCog]; _ = status[secondCog] }
            func card() -> some View { Text("\\(self[firstCog]) \\(self[secondCog])") }
            func erasedCard() -> SwiftUI.View {
              _ = self[firstCog]
              _ = self[secondCog]
              return EmptyView()
            }
            var binding: Binding<Int> {
              let first = self[firstCog]
              let second = self[secondCog]
              return Binding(get: { first + second }, set: { _ in })
            }
            func deferred() -> () -> Pair {
              { Pair(first: self[firstCog], second: self[secondCog]) }
            }
          }
          """
      ),
      CogLintFixtureExample(
        name: "Helpers outside graph extensions",
        explanation:
          "The same lexical reads outside exact `Cogs` or `CogOps` extensions are not classified.",
        source:
          """
          struct ProjectionBuilder {
            func pair(from cogs: Cogs) -> Pair {
              Pair(first: cogs[firstCog], second: cogs[secondCog])
            }
          }
          """
      ),
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Repackaging through helper data flow",
        explanation:
          "Calls to separate one-read helpers require data-flow analysis to identify the combined projection.",
        source:
          """
          extension Cogs {
            func firstValue() -> Int { self[firstCog] }
            func secondValue() -> Int { self[secondCog] }
            func pair() -> Pair {
              let first = firstValue()
              let second = secondValue()
              return Pair(first: first, second: second)
            }
          }
          typealias Runtime = Cogs
          extension Runtime {
            func hiddenPair() -> Pair { Pair(first: self[firstCog], second: self[secondCog]) }
          }
          """
      )
    ]
  )
}
