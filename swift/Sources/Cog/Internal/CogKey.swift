/// The key half of a value reference's identity, behind the layout seam.
///
/// A keyed declaration — `ManualCogBox`, `CogBox`, `AsyncCogBox` — names a
/// family of states, and `box[key]` builds a lightweight reference to one of
/// them. How that key is *physically carried* is the open question perf §4
/// records: inline `AnyHashable`, an interned token, or a generic key
/// parameter on the value reference itself. Every one of those choices moves
/// the size of a value reference, the cost of building one, and the cost of
/// hashing it during state lookup — which is why the choice waits for
/// benchmarks (perf §9) rather than being argued.
///
/// This type is where the choice lives. Nothing outside it needs to know which
/// layout is compiled in: value references, state identities, descriptors, and
/// diagnostics all say `CogKey?` and reach the original key through ``erased``.
/// `M5-09b` and `M5-09c` add candidates by rewriting this file and little else,
/// which is the entire point of introducing it before they do.
///
/// Selected at build time by `COG_TEST_VALUE_REFERENCE_LAYOUT`, which
/// `Package.swift` reads and lowers to a `COG_VALUE_REFERENCE_LAYOUT_*` define,
/// the same way it lowers the isolation matrix. A *build-time* selector rather
/// than a runtime one because the layout is a representation, and a
/// representation chosen at runtime would make every build carry the cost of
/// every candidate. An unset variable means `inline`, so an ordinary
/// `swift build` gets the correctness core's layout with nothing to configure.
///
/// `nonisolated` because `Hashable` requires nonisolated equality, matching
/// ``CogStateIdentity``, which is built on the MainActor and compared anywhere.
#if COG_VALUE_REFERENCE_LAYOUT_INLINE

/// The inline `AnyHashable` layout — the correctness core's, and the
/// baseline every candidate is measured against.
///
/// One existential box per reference. Keys of three words or fewer live
/// inline in it; larger ones allocate, which is exactly the cost the
/// interned-token candidate exists to avoid and what PERF-06 watches.
internal nonisolated struct CogKey: Hashable {
  /// The original key, type-erased.
  ///
  /// The seam's whole contract: whatever a layout stores, it can produce the
  /// key a caller passed to `box[key]`. Descriptors cast this back to their
  /// declared `Key` type, and diagnostics print it.
  let erased: AnyHashable

  /// Carries one key into the layout.
  ///
  /// - Parameter key: The value `box[key]` was given.
  init(_ key: some Hashable) {
    erased = AnyHashable(key)
  }

  /// Carries an already-erased key into the layout.
  ///
  /// Separate from the generic initializer because `AnyHashable` is itself
  /// `Hashable`: without this, erasing twice would nest one existential
  /// inside another and break equality with a singly-erased key naming the
  /// same state.
  init(erased key: AnyHashable) {
    erased = key
  }

  /// This layout's name, in the spelling `COG_TEST_VALUE_REFERENCE_LAYOUT`
  /// uses.
  ///
  /// A build says which layout it *is*, so a test can compare that against
  /// what the environment asked for. Without it the seam's worst failure is
  /// silent: a manifest that stopped reading the variable would compile every
  /// candidate identically and every candidate would still go green — the
  /// hole LEG-02 closes for the isolation matrix, closed the same way here.
  static let layoutName = "inline"
}

#endif

extension Cogs {
  /// The value-reference layout the **library** was compiled with.
  ///
  /// `package` rather than `internal` because the check that matters compares
  /// this against a test target's own define, and the two are different
  /// modules. `CogTesting` republishes it; nothing in `Cog`'s public API does.
  package static var valueReferenceLayoutNameForTesting: String { CogKey.layoutName }
}
