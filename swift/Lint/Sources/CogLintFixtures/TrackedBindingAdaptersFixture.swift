import CogLintCore

/// Adds the binding-adapter corpus to the shared fixture inventory.
extension CogLintFixtureRegistry {
  /// The executable examples, positions, and documented evasions for `tracked-binding-adapters`.
  package static let trackedBindingAdapters = CogLintRuleFixture(
    rule: TrackedBindingAdaptersRule(),
    documentation: CogLintRuleDocumentation(
      violation:
        "A `Binding` over graph state is constructed inside a view, or a binding getter reads through `peek` instead of a tracked read.",
      rationale:
        "Cog vends no binding helper, so every binding over graph state is an app's own adapter and the convention supplies the shape the library does not. A getter that peeks registers no dependency, so the control renders once and then silently stops following the fact it displays — a failure that looks like a rendering bug rather than a read bug. Constructing bindings inline in views spreads the writable surface across the view layer, so no single file answers what the system may mutate, which is the reason the adapters were collected onto the runtime in the first place.",
      repair:
        "Move the binding into the rig's `+Bindings.swift` file as a member of `extension Cogs`, and give it the one adapter shape: a getter that reads with the tracked subscript, and a setter that calls a named `CogOps` operation. Call that adapter from the view."
    ),
    triggering: [
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Bindings assembled inside a view",
          explanation:
            "A binding whose closures touch the runtime is a writable surface, and every one of those belongs in the adapter file rather than in a body.",
          source:
            """
            struct FilterBar: View {
              @Environment(\\.cogs) private var cogs

              var body: some View {
                let todoFilter = cogs[todoFilterCog]
                Picker(
                  "Filter",
                  selection: Binding(get: { todoFilter }, set: { cogs.selectTodoFilter($0) })
                ) {
                  Text("All")
                }
                Toggle("Done", isOn: Binding(get: { cogs[isDoneCog] }, set: { cogs.setDone($0) }))
              }
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 8, column: 18),
          CogLintFixturePosition(line: 12, column: 26),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Adapter getters that peek",
          explanation:
            "Bare and `self`-qualified peeks both read without registering, so the control never learns the value changed.",
          source:
            """
            extension Cogs {
              var searchQueryBinding: Binding<String> {
                Binding(
                  get: { self.peek(searchQueryCog) },
                  set: { self.typeSearchQuery($0) }
                )
              }
              func draftBinding(for id: TodoID) -> Binding<String> {
                Binding(get: { peek(draftCogs[id]) }, set: { self.editDraft($0, for: id) })
              }
            }
            """
        ),
        positions: [
          CogLintFixturePosition(line: 4, column: 19),
          CogLintFixturePosition(line: 9, column: 20),
        ]
      ),
      CogLintTriggeringExample(
        example: CogLintFixtureExample(
          name: "Status-lens peek through an explicit initializer",
          explanation:
            "The status lens is the same untracked read, and a generically specialized `.init` still names `Binding` in source.",
          source:
            """
            extension Cogs {
              var currentZipBinding: Binding<ZipCode?> {
                Binding<ZipCode?>.init(
                  get: { self.status.peek(currentZipCog).value },
                  set: { self.selectCurrentLocation($0) }
                )
              }
            }
            """
        ),
        positions: [CogLintFixturePosition(line: 4, column: 26)]
      ),
    ],
    nonTriggering: [
      CogLintFixtureExample(
        name: "Conforming runtime adapters",
        explanation:
          "Each adapter pairs a tracked getter with a named operation, which is the one shape the convention asks for.",
        source:
          """
          extension Cogs {
            var todoFilterBinding: Binding<TodoFilter> {
              Binding(
                get: {
                  let todoFilter = self[todoFilterCog]
                  return todoFilter
                },
                set: { self.selectTodoFilter($0) }
              )
            }
            func tabPathBinding(for tab: TrailTab) -> Binding<[TrailRoute]> {
              Binding(
                get: {
                  let tabPath = self[tabPathCogs[tab]]
                  return tabPath
                },
                set: { self.setPath($0, in: tab) }
              )
            }
          }
          """
      ),
      CogLintFixtureExample(
        name: "Views that call adapters and bind local state",
        explanation:
          "A view may build bindings over its own `@State`; only bindings that reach the runtime are collected.",
        source:
          """
          struct ComposerField: View {
            @Environment(\\.cogs) private var cogs
            @State private var draft = ""

            var body: some View {
              let newTodoTitle = cogs[newTodoTitleCog]
              TextField("Draft", text: Binding(get: { draft }, set: { draft = $0 }))
              TextField("Todo", text: cogs.newTodoTitleBinding)
              Text(newTodoTitle)
            }
          }
          """
      ),
      CogLintFixtureExample(
        name: "Setter peeks and non-constructed bindings",
        explanation:
          "Only the getter must register, and projections and factory members name no construction to inspect.",
        source:
          """
          extension Cogs {
            var quantityBinding: Binding<Int> {
              Binding(
                get: {
                  let quantity = self[quantityCog]
                  return quantity
                },
                set: { self.changeQuantity(to: $0, from: self.peek(quantityCog)) }
              )
            }
          }
          struct QuantityStepper: View {
            @State private var draft = Draft()

            var body: some View {
              Stepper("Quantity", value: $draft.quantity)
              Toggle("Locked", isOn: .constant(true))
            }
          }
          """
      ),
    ],
    acceptedEvasions: [
      CogLintFixtureExample(
        name: "Bindings outside recognizable views and receivers",
        explanation:
          "A `View` conformance written in another file hides the placement policy, and an explicitly passed `Cogs` parameter is not a classified receiver, so neither peek nor placement is provable here.",
        source:
          """
          struct SavedToggle {
            @Environment(\\.cogs) private var cogs

            var savedBinding: Binding<Bool> {
              Binding(get: { self.cogs[isSavedCog] }, set: { self.cogs.setSaved($0) })
            }
          }

          func untrackedBinding(_ cogs: Cogs) -> Binding<Bool> {
            Binding(get: { cogs.peek(isSavedCog) }, set: { _ in })
          }
          """
      )
    ]
  )
}
