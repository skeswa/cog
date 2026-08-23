import Cog
import CogTesting
import Testing

// MARK: - The scoped assembly seam

// Not a scenario: `CogTesting.withAssembledCogs` calls the real
// `assemble()`, so the production guard reaches inside the test seam too,
// and nesting the seam is a second install. That is intended — the inner
// scope's exit would otherwise uninstall the outer scope's context and leave
// two tests sharing one graph — and it is worth one child process to pin it,
// because the alternative failure is silent.

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
