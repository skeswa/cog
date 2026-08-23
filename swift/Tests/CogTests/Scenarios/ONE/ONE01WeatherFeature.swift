import Cog

// The source and write op live in a different feature file from the reader,
// matching an app's ownership boundary.
@MainActor private let _selectedZipCog = Cog<String?>.Manual(nil, name: "selectedZip")

extension Cogs {
  /// The feature op: an ordinary context method beside the source it owns.
  func selectZip(_ zip: String?) {
    turn { c in
      c[_selectedZipCog] = zip
    }
  }

  /// The feature's read path, which another feature can call with the context
  /// it received at its composition boundary.
  func selectedWeatherZip() -> String? {
    peek(_selectedZipCog)
  }
}
