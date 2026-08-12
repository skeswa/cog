import Cog

// The feature file that owns `ONE-01`'s source and write path. It is separate
// from both the scenario test and the settings feature that reads the result,
// so the round trip has the same file boundary as a real app.
//
// Written the way §4 says a real feature file is written — the source is
// private to the file that owns it, and the rest of the app gets reads and
// ops instead — so what the scenario test exercises is the same arrangement an
// app would have, not a test-shaped shortcut.
//
/// The zip code the weather feature is showing.
///
/// `@MainActor` is stated rather than inherited because this file compiles in
/// all four legs of the isolation matrix, and a bare file-scope `let` of a
/// MainActor-isolated type would mean different things in the MainActor and
/// nonisolated legs (§7).
@MainActor private let selectedZipSource = ManualCog<String?>(nil, name: "selectedZip")

extension Cogtext {
  /// The feature op: an ordinary context method beside the source it owns.
  func selectZip(_ zip: String?) {
    commit { w in
      w[selectedZipSource] = zip
    }
  }

  /// The feature's read path, which another feature can call with the context
  /// it received at its composition boundary.
  func selectedWeatherZip() -> String? {
    read(selectedZipSource)
  }
}
