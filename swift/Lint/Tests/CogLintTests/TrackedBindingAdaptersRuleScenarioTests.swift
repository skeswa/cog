import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-25, LINT-26

/// Proves both halves of the binding rule against their shared fixture positions.
@Test func `LINT-25 binding adapter fixture is the rule specification`() {
  #expect(
    CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.trackedBindingAdapters).isEmpty
  )
}

/// Proves the registered engine reports a view-local graph binding with the settled diagnostic.
@Test func `LINT-25 production registry reports a graph binding built in a view`() throws {
  let execution = try lintTrackedBindingSource(
    """
    struct FilterBar: View {
      @Environment(\\.cogs) private var cogs
      var body: some View {
        Toggle("Done", isOn: Binding(get: { cogs[isDoneCog] }, set: { cogs.setDone($0) }))
      }
    }
    """
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "Bindings.swift:4:26: error: [tracked-binding-adapters] a `Binding` over graph state belongs in a `Cogs` extension adapter, not in a view; call the adapter from the view instead — https://skeswa.github.io/cog/documentation/cog/trackedbindingadapters\n"
  )
}

/// Proves an untracked adapter getter reports at the peek rather than at the member.
@Test func `LINT-26 production registry reports an untracked adapter getter`() throws {
  let execution = try lintTrackedBindingSource(
    """
    extension Cogs {
      var searchQueryBinding: Binding<String> {
        Binding(get: { self.peek(searchQueryCog) }, set: { self.typeSearchQuery($0) })
      }
    }
    """
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "Bindings.swift:3:25: error: [tracked-binding-adapters] a binding getter must read trackably; `peek` registers no dependency, so the control stops following this value — https://skeswa.github.io/cog/documentation/cog/trackedbindingadapters\n"
  )
}

/// Proves the placement and tracking halves never both report one construction.
@Test func `LINT-26 a view binding that peeks reports placement only`() throws {
  let execution = try lintTrackedBindingSource(
    """
    struct FilterBar: View {
      @Environment(\\.cogs) private var cogs
      var body: some View {
        Toggle("Done", isOn: Binding(get: { cogs.peek(isDoneCog) }, set: { cogs.setDone($0) }))
      }
    }
    """
  )

  #expect(execution.findings.count == 1)
  #expect(execution.findings.first?.column == 26)
}

/// Runs the complete production registry over one scratch source buffer.
private func lintTrackedBindingSource(_ source: String) throws -> CogLintExecution {
  try lintScratchSource(source + "\n", named: "Bindings.swift")
}
