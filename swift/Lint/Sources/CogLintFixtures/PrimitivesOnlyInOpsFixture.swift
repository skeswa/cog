import CogLintCore

/// Adds the named-domain-operation corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `primitives-only-in-ops`.
  package static let primitivesOnlyInOps = CogLintRuleFixture(
    rule: PrimitivesOnlyInOpsRule(),
    documentation: CogLintRuleDocumentation(
      violation:
        "Production code calls `commit` or `refresh` outside a bare primitive call in an `extension CogOps` domain operation.",
      rationale:
        "Graph primitives describe how Cog performs work, not what the application is asking for. Named operations keep the domain verb beside its state declarations, give every call site one readable intent, and apply the same boundary to views, mechanisms, selectors, writers, and runtime helpers.",
      repair:
        "Move the primitive into a named method on `CogOps`, spell `commit(...)` or `refresh(...)` bare there, and call that domain method through the capability at the original site. Tests may select the explicit test target role when they need to drive primitives directly."
    ),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Environment and bootstrap primitives",
          explanation:
            "View and bootstrap graph receivers must call domain operations instead of primitives.",
          source:
            """
            struct CounterCard: View {
              @Environment(\\.cogs) private var cogs
              func increment() {
                cogs.commit { c in c[countSourceCog] += 1 }
                self.cogs.refresh(forecastCog)
              }
            }
            func launch() {
              let appGraph = Cogs.bootstrapApp()
              appGraph.commit(countSourceCog, to: 1)
              appGraph.refresh(forecastCog)
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 4, column: 10),
          CogLintFixturePosition(line: 5, column: 15),
          CogLintFixturePosition(line: 10, column: 12),
          CogLintFixturePosition(line: 11, column: 12),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Reader writer and mechanism primitives",
          explanation:
            "Every classifier-proven capability stays behind the same named-operation boundary.",
          source:
            """
            let invalidCog = Cog<Int> { c in c.refresh(forecastCog); return 0 }
            func overwrite(_ c: Writer) { c.commit(named: "nested") { _ in } }
            struct Loader: Mechanism {
              func operate(_ m: MechanismController) {
                m.commit(countSourceCog, to: 1)
                m.refresh(forecastCog)
                m.run { c in c.refresh(forecastCog) }
                m.whenever(enabledCog) { child in child.commit(countSourceCog, to: 2) }
              }
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 1, column: 36),
          CogLintFixturePosition(line: 2, column: 33),
          CogLintFixturePosition(line: 5, column: 7),
          CogLintFixturePosition(line: 6, column: 7),
          CogLintFixturePosition(line: 7, column: 20),
          CogLintFixturePosition(line: 8, column: 45),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Runtime extension primitives",
          explanation:
            "A `Cogs` extension cannot disguise a primitive as an application helper.",
          source:
            """
            extension Cogs {
              func resetInline() {
                commit(countSourceCog, to: 0)
                self.refresh(forecastCog)
              }
            }
            extension CogOps {
              func wronglyQualified() { self.commit(countSourceCog, to: 0) }
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 3, column: 5),
          CogLintFixturePosition(line: 4, column: 10),
          CogLintFixturePosition(line: 8, column: 34),
        ]
      ),
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "Bare primitives inside named operations",
        explanation:
          "A `CogOps` extension may use bare primitives through nested writer and helper closures.",
        source:
          """
          extension CogOps {
            func selectCount(_ value: Int) {
              commit(countSourceCog, to: value)
              commit { c in
                c[countSourceCog] = value
                withAnimation { commit(otherSourceCog, to: value) }
              }
            }
            func refreshForecast() { refresh(forecastCog) }
          }
          struct CounterCard: View {
            @Environment(\\.cogs) private var cogs
            func increment() { cogs.selectCount(1) }
          }
          """
      ),
      CogLintFixtureExample(
        name: "Unrelated method names",
        explanation: "Calls on unclassified values do not become Cog primitives by spelling alone.",
        source:
          """
          func update(cache: Cache) {
            cache.commit()
            cache.refresh()
          }
          """
      ),
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Syntax-hidden graph capability",
        explanation:
          "Factories and typealiases that hide receiver identity remain outside the syntax-only classifier.",
        source:
          """
          typealias Controller = MechanismController
          func hidden(_ controller: Controller) { controller.commit(countSourceCog, to: 1) }
          func inferred() {
            let graph = makeCogs()
            graph.refresh(forecastCog)
          }
          """
      )
    ]
  )
}
