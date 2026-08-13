import Cog
import CogTesting
import Testing

// Scoped bootstrap keeps the process-wide app install from leaking into other
// tests.

// MARK: - ONE-01

@MainActor
@Test func `ONE-01 an op and a read in separate features share the bootstrapped context`() {
  Cogs.withBootstrappedApp { cogs in
    #expect(Cogs.isBootstrappedApp(cogs))
    #expect(SettingsFeature.selectedWeatherZip(in: cogs) == nil)

    cogs.selectZip("10001")

    #expect(SettingsFeature.selectedWeatherZip(in: cogs) == "10001")
    #expect(Cogs.isBootstrappedApp(cogs))
  }
}
