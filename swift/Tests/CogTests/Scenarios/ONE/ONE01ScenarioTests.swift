import Cog
import CogTesting
import Testing

// Scoped bootstrap keeps the process-wide app install from leaking into other
// tests.

// MARK: - ONE-01

@MainActor
@Test func `ONE-01 an op and a read in separate features share the bootstrapped context`() {
  Cogtext.withBootstrappedApp { cogs in
    #expect(Cogtext.isBootstrappedApp(cogs))
    #expect(SettingsFeature.selectedWeatherZip(in: cogs) == nil)

    cogs.selectZip("10001")

    #expect(SettingsFeature.selectedWeatherZip(in: cogs) == "10001")
    #expect(Cogtext.isBootstrappedApp(cogs))
  }
}
