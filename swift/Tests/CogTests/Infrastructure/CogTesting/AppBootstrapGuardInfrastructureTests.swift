import Cog
import CogTesting
import Testing

// MARK: - The scoped bootstrap seam

// Not a scenario: `CogTesting.withBootstrappedApp` calls the real
// `bootstrapApp()`, so the production guard reaches inside the test seam too,
// and nesting the seam is a second install. That is intended — the inner
// scope's exit would otherwise uninstall the outer scope's context and leave
// two tests sharing one graph — and it is worth one child process to pin it,
// because the alternative failure is silent.

@MainActor
@Test func `AppBootstrapGuardInfrastructure nesting the scoped bootstrap seam traps`() async {
  await #expect(processExitsWith: .failure) {
    await MainActor.run {
      Cogs.withBootstrappedApp { _ in
        Cogs.withBootstrappedApp { _ in }
      }
    }
  }
}
