/// A value type that can vouch for its own honest resting value.
///
/// Every async cog rests on a declared default so that its value reads are
/// total (§5.1): before any generation succeeds, a value read returns the
/// default rather than a phase or an implicit `nil`. The default is a required
/// invariant of the declaration but an omittable argument of its initializer —
/// omission is legal exactly when `Value` conforms to this protocol and can
/// therefore supply the resting value itself.
///
/// The library conforms only `Optional`, resting at `nil`, so declaring an
/// optional value is the entire spelling for "nothing until the first
/// success." Blanket conformances for collections or numbers are deliberately
/// absent: a process-wide "every array rests at empty" would install a
/// dishonest empty state everywhere at once. An app may conform its own domain
/// types when — and only when — the resting value renders honestly while work
/// is still in flight; the conformance is the type author vouching once, in
/// the `EnvironmentKey.defaultValue` tradition.
public nonisolated protocol CogDefaultable {
  /// The honest resting value shown before any generation has succeeded.
  ///
  /// This is read once per async declaration, at initialization on the
  /// declaring thread, and captured by that declaration's value projection.
  /// It must be safe to produce without a graph: no Cog reads, no MainActor
  /// requirement.
  static var cogDefault: Self { get }
}

/// `Optional` rests at `nil`: the one universally honest "nothing yet."
///
/// This is the conformance that makes `AsyncCog<Weather?> { ... }` compile
/// without a `default:` argument. A retained successful `nil` remains
/// distinct from this resting `nil` in the phase — `Previous/some(nil)`
/// versus `Previous/none` — even though a value read cannot tell them apart,
/// which is the ambiguity the declaring author accepted by choosing an
/// optional value.
extension Optional: CogDefaultable {
  /// Rests at `nil` until the first success is accepted.
  public static var cogDefault: Self { nil }
}
