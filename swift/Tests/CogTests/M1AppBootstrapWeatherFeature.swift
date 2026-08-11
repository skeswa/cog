import Cog

// One of the two stand-in "feature files" that `ONE-01` needs. It is a
// separate file on purpose: the scenario is about a declaration living in one
// feature and being reachable from another part of the app, and that is not
// something a single file can demonstrate.
//
// Written the way §4 says a real feature file is written — the source is
// private to the file that owns it, and the rest of the app gets reads and
// ops instead — so what the scenario test exercises is the same arrangement an
// app would have, not a test-shaped shortcut.
//
// Nothing here is handed a context. That is the point of the scenario: this
// file was compiled without knowing anything about the app's entry point, and
// it still resolves through the app's one graph.

/// The zip code the weather feature is showing.
///
/// `@MainActor` is stated rather than inherited because this file compiles in
/// all four legs of the isolation matrix, and a bare file-scope `let` of a
/// MainActor-isolated type would mean different things in the MainActor and
/// nonisolated legs (§7).
@MainActor private let selectedZipSource = ManualCog<String?>(nil, name: "selectedZip")

/// A feature that keeps its state in the app's graph and its declaration to
/// itself.
@MainActor
enum WeatherFeature {
  /// The context this feature resolves through.
  ///
  /// A real feature would rarely spell this out; it reads and writes and never
  /// mentions the context it is doing so in. The scenario needs the answer
  /// itself, because "one app, one graph" is a claim about which context that
  /// is.
  static var context: Cogtext {
    Cogtext.app
  }

  /// The zip code, read through the app's context from inside the feature.
  static func selectedZip() -> String? {
    Cogtext.app.read(selectedZipSource)
  }

  // The op that writes `selectedZipSource` belongs here too, and `ONE-01`
  // asks for it: an op in this file commits a write, and a read elsewhere
  // sees it. `commit` does not exist yet — `M1-04ab` adds staging and the
  // flush — so the write half of the scenario cannot be spelled at all, and
  // `M1AppBootstrapTests.swift` says so where it stops short. Add
  // `selectZip(_:)` here when the turn machinery lands.
}
