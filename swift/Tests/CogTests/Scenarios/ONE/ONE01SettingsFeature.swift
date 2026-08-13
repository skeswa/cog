import Cog

// A second feature file, separate from the source and op. It receives the app
// context at its composition boundary just as a view receives `\.cogs` from
// the environment, then reads the weather feature through that same graph.
@MainActor
enum SettingsFeature {
  static func selectedWeatherZip(in cogs: Cogs) -> String? {
    cogs.selectedWeatherZip()
  }
}
