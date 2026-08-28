import Cog
import CogTesting
import Testing

// MARK: - The scoped assembly seam

// Not a scenario: `CogTesting.withAssembledCogs` calls the real
// `assemble()`, so the production guard also covers the test seam. Nesting it
// is a second install. Without the trap, the inner exit would uninstall the
// outer context and leave two tests sharing one graph. A child process pins
// this failure because it would otherwise be silent.

@MainActor
@Test func `AssemblyGuardInfrastructure nesting the scoped assembly seam traps`() async {
  await #expect(processExitsWith: .failure) {
    await MainActor.run {
      Cogs.withAssembledCogs { _ in
        Cogs.withAssembledCogs { _ in }
      }
    }
  }
}
