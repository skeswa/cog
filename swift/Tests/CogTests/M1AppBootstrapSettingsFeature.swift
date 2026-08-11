import Cog

// The second stand-in feature file. Two features, neither of which knows the
// other exists and neither of which was handed a context, are what make
// "shared app-wide" a claim with something behind it: one file reaching the
// app context could be a coincidence of how the test was written, two cannot.

/// Whether the user asked for temperatures in Celsius.
@MainActor private let usesCelsiusSource = ManualCog<Bool>(true, name: "usesCelsius")

/// A second feature, in a second file, resolving through the same graph.
@MainActor
enum SettingsFeature {
  /// The context this feature resolves through.
  static var context: Cogtext {
    Cogtext.app
  }

  /// The unit preference, read through the app's context.
  static func usesCelsius() -> Bool {
    Cogtext.app.read(usesCelsiusSource)
  }
}
