import Cog
import CogTesting
import Testing

// `ONE-01`, the app install. Public `Cog` API and the `CogTesting` product
// only — no `@testable`, nothing that could notice how a context stores
// anything (scenarios.md constraint 3).
//
// The scenario runs inside the scoped bootstrap fixture `CogTesting` vends.
// The app install is process-global while a test suite is one process, so the
// synchronous MainActor scope removes the install before another test can run.

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
