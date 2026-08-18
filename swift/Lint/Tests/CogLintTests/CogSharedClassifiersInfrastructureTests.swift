import CogLintCore
import Testing

/// Proves same-file view/app evidence joins extensions while cross-file and alias evidence miss.
@Test func viewAppClassifierInfrastructure() {
  let source = CogLintParser.parse(
    source:
      """
      struct DirectCard: SwiftUI.View {
        var body: some View { EmptyView() }
      }

      struct BodyOnlyCard {
        var body: some SwiftUI.View { EmptyView() }
      }

      struct ExtensionCard {
        let title: String
      }
      extension ExtensionCard: View {
        var body: some View { Text(title) }
      }

      typealias Screen = View
      struct AliasCard: Screen {
        var bodyValue: Int { 0 }
      }

      struct CrossFileCard {
        let title: String
      }

      struct DirectApp: SwiftUI.App {
        var body: some Scene { WindowGroup { EmptyView() } }
      }

      struct ExtensionApp {}
      extension ExtensionApp: App {
        var body: some Scene { WindowGroup { EmptyView() } }
      }

      typealias Application = App
      struct AliasApp: Application {}
      struct CrossFileApp {}
      """
  )

  let views = CogViewClassifier.classify(in: source)
  #expect(views.map(\.qualifiedName) == ["DirectCard", "BodyOnlyCard", "ExtensionCard"])
  #expect(views.map(\.memberBlocks.count) == [1, 1, 2])

  let apps = CogAppEntryClassifier.classify(in: source)
  #expect(apps.map(\.qualifiedName) == ["DirectApp", "ExtensionApp"])
  #expect(apps.map(\.memberBlocks.count) == [1, 2])
}

/// Proves environment, selector, reaction, writer, mechanism, and bootstrap receiver seams.
@Test func graphReceiverClassifierInfrastructure() {
  let source = CogLintParser.parse(
    source:
      """
      let doubledCog = Cog<Int> { c in c[countCog] * 2 }
      let tripledCog: Cog<Int> = .init { c in c[countCog] * 3 }

      struct CounterCard: View {
        @Environment(\\.cogs) private var cogs

        var body: some View {
          Button("Increment") {
            cogs.commit { c in c[countSourceCog] += 1 }
          }
        }
      }

      struct CounterMechanism: Mechanism {
        func operate(_ m: Cog.MechanismController) {
          m.run { c in _ = c[countCog] }
          m.commit { c in c[countSourceCog] = 0 }
          m.whenever(enabledCog) { s in
            s.run { c in _ = c[countCog] }
          }
        }
      }

      struct CounterApp: App {
        init() {
          let cogs = Cogs.bootstrapApp()
          cogs.commit { c in c[countSourceCog] = 1 }

          let hiddenCogs = makeCogs()
          hiddenCogs.commit { c in c[countSourceCog] = 2 }
          unknown.run { c in _ = c[countCog] }
        }
      }
      """
  )

  let classifications = CogGraphReceiverClassifier.classify(in: source)

  #expect(
    classifications.map(receiverSummary) == [
      "c:selector",
      "c:selector",
      "cogs:environment",
      "c:writer",
      "m:mechanism",
      "c:reaction",
      "c:writer",
      "s:mechanism",
      "c:reaction",
      "cogs:bootstrap",
      "c:writer",
    ]
  )
}

/// Renders receiver kinds compactly while preserving the classifier's source order.
private func receiverSummary(_ classification: CogGraphReceiverClassification) -> String {
  let kind: String
  switch classification.kind {
  case .environmentCogs: kind = "environment"
  case .selectorReader: kind = "selector"
  case .reactionReader: kind = "reaction"
  case .writer: kind = "writer"
  case .mechanismController: kind = "mechanism"
  case .bootstrapCogs: kind = "bootstrap"
  }
  return "\(classification.name):\(kind)"
}
