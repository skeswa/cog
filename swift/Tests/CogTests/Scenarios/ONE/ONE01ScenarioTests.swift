import Cog
import CogTesting
import Testing

// Scoped assembly keeps the process-wide app install from leaking into other
// tests.

// MARK: - ONE-01

@MainActor
@Test func `ONE-01 an op and a read in separate features share the assembled context`() {
  Cogs.withAssembledCogs { cogs in
    #expect(Cogs.isAssembledCogs(cogs))
    #expect(SettingsFeature.selectedWeatherZip(in: cogs) == nil)

    cogs.selectZip("10001")

    #expect(SettingsFeature.selectedWeatherZip(in: cogs) == "10001")
    #expect(Cogs.isAssembledCogs(cogs))
  }
}
