#if DEBUG

public import Cog

extension Cogs {
  /// Seeds a manual source before a deterministic test or preview begins.
  ///
  /// Seeding applies the source's equality rule and invalidates dependents, but
  /// opens no turn, runs no reaction, and computes nothing eagerly. Use it only
  /// while an isolated testing context is idle. Production code that imports
  /// only `Cog` cannot call this setup API.
  ///
  /// - Parameters:
  ///   - valueReference: The exact manual descriptor-and-key state to seed.
  ///   - value: The candidate value, installed only when the source's equality
  ///     rule considers it changed.
  public func seed<Value>(_ valueReference: Cog<Value>.Manual, to value: Value) {
    seedForTesting(valueReference, to: value)
  }
}

#endif
