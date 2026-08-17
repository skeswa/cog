/// The key half of a value reference's identity, behind the layout seam.
///
/// A keyed declaration — `ManualCogBox`, `CogBox`, `AsyncCogBox` — names a
/// family of states, and `box[key]` builds a lightweight reference to one of
/// them. Perf §4 and §9.6 select inline `AnyHashable` for the shipping build
/// after comparing it with an interned token and a generic box-produced
/// reference. The selector keeps all three implementations available to the
/// behavior and benchmark suites; an ordinary build always takes the selected
/// inline branch.
///
/// This type isolates the two erased layouts. Value references, state
/// identities, descriptors, and diagnostics say `CogKey?` and reach the
/// original key through ``erased``. The generic candidate necessarily adds
/// box-produced keyed reference types at the public read surface, then adapts
/// them to this type only after a runtime capability receives them.
///
/// Selected at build time by `COG_TEST_VALUE_REFERENCE_LAYOUT`, which
/// `Package.swift` reads and lowers to a `COG_VALUE_REFERENCE_LAYOUT_*` define,
/// the same way it lowers the isolation matrix. A *build-time* selector rather
/// than a runtime one because the layout is a representation, and a
/// representation chosen at runtime would make every build carry the cost of
/// every candidate. An unset variable means the selected `inline` layout.
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

#elseif COG_VALUE_REFERENCE_LAYOUT_INTERNED

internal import Foundation

/// The interned-token layout — a candidate, never the default.
///
/// A key is carried as one `Int`, and a process-wide table remembers what that
/// integer stands for. The trade this candidate is measured on:
///
/// - A value reference is narrower than the inline layout's existential box,
///   and a large key — a `String` ZIP, a struct wider than three words — is
///   interned once instead of being copied into every reference that names it.
///   That is the allocation PERF-06 watches.
/// - Equality and hashing become `Int` comparison, which matters because state
///   lookup hashes a `CogStateIdentity` on **every** read.
/// - The table never shrinks. A screen that churns a thousand keys interns a
///   thousand entries and keeps them for the life of the process. That is the
///   cost COUNT-08's churn shape exists to expose, and it is why this is a
///   candidate rather than an obvious improvement.
///
/// The table is locked rather than actor-isolated because `CogKey` is
/// `nonisolated` — `Hashable` requires it, and identities travel with async
/// completions. The lock is not in a graph walk and does not violate perf §5:
/// the hot path is equality and hashing, which touch only the token. Only
/// construction and ``erased`` take it.
internal nonisolated struct CogKey: Hashable {
  /// What this key interned to.
  private let token: Int

  /// The original key, type-erased.
  ///
  /// Reconstituted from the table, so the seam's contract holds even though
  /// nothing about the original is stored in the reference itself. Callers use
  /// it to cast back to a declared `Key` and to render diagnostics, both cold
  /// paths.
  var erased: AnyHashable { CogKeyInternTable.shared.key(for: token) }

  /// Carries one key into the layout, interning it.
  ///
  /// - Parameter key: The value `box[key]` was given.
  init(_ key: some Hashable) {
    token = CogKeyInternTable.shared.token(for: AnyHashable(key))
  }

  /// Carries an already-erased key into the layout.
  ///
  /// Separate from the generic initializer for the reason the inline layout
  /// gives: `AnyHashable` is itself `Hashable`, and erasing twice would intern
  /// a nested existential under a different token than the singly erased key
  /// naming the same state.
  init(erased key: AnyHashable) {
    token = CogKeyInternTable.shared.token(for: key)
  }

  /// This layout's name, in the spelling `COG_TEST_VALUE_REFERENCE_LAYOUT`
  /// uses.
  static let layoutName = "interned"
}

/// The process-wide key table this layout interns into.
///
/// Process-wide rather than per-`Cogs`, on purpose. Tokens ride inside
/// ``CogStateIdentity``, which is `nonisolated` and outlives any one context; a
/// per-context table would make a token meaningless the moment an identity
/// crossed a boundary, and every candidate has to survive the same behavior
/// suite the inline layout does.
///
/// `@unchecked Sendable` because the lock is what makes it safe, and the
/// compiler cannot see that.
private nonisolated final class CogKeyInternTable: @unchecked Sendable {
  /// The one table. Interning is only meaningful if everyone shares it.
  static let shared = CogKeyInternTable()

  /// Guards both directions of the mapping.
  private let lock = NSLock()

  /// Key to token, for interning.
  private var tokensByKey: [AnyHashable: Int] = [:]

  /// Token to key, for ``CogKey/erased``. An array because tokens are dense and
  /// issued in order.
  private var keysByToken: [AnyHashable] = []

  /// Interns a key, returning the token that stands for it.
  ///
  /// Equal keys always return the same token — that equivalence *is* the
  /// layout, since it is what lets equality and hashing skip the key itself.
  ///
  /// - Parameter key: The erased key to intern.
  /// - Returns: Its stable token.
  func token(for key: AnyHashable) -> Int {
    lock.lock()
    defer { lock.unlock() }
    if let existing = tokensByKey[key] { return existing }
    let token = keysByToken.count
    keysByToken.append(key)
    tokensByKey[key] = token
    return token
  }

  /// Recovers the key a token stands for.
  ///
  /// - Parameter token: A token this table issued.
  /// - Returns: The key it was interned from.
  func key(for token: Int) -> AnyHashable {
    lock.lock()
    defer { lock.unlock() }
    guard token >= 0, token < keysByToken.count else {
      // `fatalError`, not `preconditionFailure`: the message is composed, and
      // an optimized `preconditionFailure` drops composed messages.
      fatalError(
        """
        A value reference carried token \(token), which this process never \
        issued. Tokens come only from this table and are never rewritten, so a \
        token it does not recognize means a value reference was built from \
        uninitialized or corrupted memory.
        """
      )
    }
    return keysByToken[token]
  }
}

#elseif COG_VALUE_REFERENCE_LAYOUT_GENERIC

/// The simple core's erased storage identity in a generic-reference build.
///
/// Box-produced value references retain their concrete `Key` type and value;
/// this type appears only when the class-state correctness core files the
/// reference in its heterogeneous state dictionary. Keeping that conversion
/// behind the runtime API makes its cost part of the whole-candidate benchmark
/// instead of charging `box[key]` construction for existential storage.
internal nonisolated struct CogKey: Hashable {
  /// The original key, erased at the correctness-core storage boundary.
  let erased: AnyHashable

  /// Erases a generic reference's concrete key for heterogeneous state storage.
  init(_ key: some Hashable) {
    erased = AnyHashable(key)
  }

  /// Preserves an already-erased identity without nesting `AnyHashable`.
  init(erased key: AnyHashable) {
    erased = key
  }

  /// This candidate's build-selector spelling.
  static let layoutName = "generic"
}

#else

#error("Package.swift defined no value-reference layout for the Cog library")

#endif

extension Cogs {
  /// The value-reference layout the **library** was compiled with.
  ///
  /// `package` rather than `internal` because the check that matters compares
  /// this against a test target's own define, and the two are different
  /// modules. `CogTesting` republishes it; nothing in `Cog`'s public API does.
  package static var valueReferenceLayoutNameForTesting: String { CogKey.layoutName }
}
