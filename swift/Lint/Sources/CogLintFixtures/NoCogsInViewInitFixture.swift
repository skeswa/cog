import CogLintCore

/// Adds the SwiftUI graph-boundary corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `no-cogs-in-view-init`.
  package static let noCogsInViewInit = CogLintRuleFixture(
    rule: NoCogsInViewInitRule(),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Stored graph runtime",
          explanation:
            "A recognized view must resolve the runtime from its environment instead of storing it.",
          source:
            """
            struct Dashboard: View {
              let cogs: Cogs
              var optionalRuntime: Cogs?
              var wrappedRuntime: Holder<Cogs>
              var body: some View { EmptyView() }
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 2, column: 13),
          CogLintFixturePosition(line: 3, column: 24),
          CogLintFixturePosition(line: 4, column: 30),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Initializer and method forwarding",
          explanation:
            "Initializer and method parameters cannot carry `Cogs`, even through optional or generic types.",
          source:
            """
            struct Dashboard { var body: some View { EmptyView() } }
            extension Dashboard {
              init(cogs: Swift.Optional<Cog.Cogs>) {}
              func render(using runtime: Result<Cogs, Error>) {}
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 3, column: 33),
          CogLintFixturePosition(line: 4, column: 37),
        ]
      ),
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "Environment-owned graph access",
        explanation:
          "Each view resolves `cogs` itself and accepts only domain values and identities.",
        source:
          """
          struct Dashboard: View {
            @Environment(\\.cogs) private var cogs
            let accountID: Account.ID
            init(accountID: Account.ID) { self.accountID = accountID }
            func title(for account: Account) -> String { account.name }
            var body: some View { EmptyView() }
          }
          """
      )
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Syntax-hidden view or runtime identity",
        explanation:
          "Inferred runtime values, aliases, and cross-file view conformance remain outside syntax-only recognition.",
        source:
          """
          typealias Runtime = Cogs
          struct ExternalView {
            let inferred = makeCogs()
            let aliased: Runtime
            let written: Cogs
          }
          """
      )
    ]
  )
}
