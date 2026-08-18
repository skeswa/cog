import Cog

// The source and write op live in a different feature file from the reader,
// matching an app's ownership boundary.
@MainActor private let selectedZipSourceCog = ManualCog<String?>(nil, name: "selectedZip")

extension Cogs {
  /// The feature op: an ordinary context method beside the source it owns.
  func selectZip(_ zip: String?) {
    commit { c in
      c[selectedZipSourceCog] = zip
    }
  }

  /// The feature's read path, which another feature can call with the context
  /// it received at its composition boundary.
  func selectedWeatherZip() -> String? {
    peek(selectedZipSourceCog)
  }
}
