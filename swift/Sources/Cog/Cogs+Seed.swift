#if DEBUG

// MARK: - Test seeding

extension Cogs {
  /// Implements deterministic manual-source setup for `CogTesting`.
  ///
  /// This package seam is the exception to ordinary turn-based writes. It
  /// applies the source's equality rule and marks dependent cogs for later
  /// settlement, but opens no turn and computes nothing eagerly. Only the
  /// `CogTesting` product publishes it to clients. Seed only while the context
  /// is idle; seeding during graph work would break its snapshot.
  ///
  /// A changed seed advances the context revision, updates an existing or
  /// lazily created app-lifetime manual state, invalidates dependents, and
  /// defers any installed Observation boundary notification. It deliberately
  /// creates no turn or history entry and runs no reaction before returning;
  /// subsequent reads and turn flushing settle affected work through the normal
  /// paths, and the next turn consumes any deferred UI notification. An equal
  /// seed is a complete no-op, including no revision advance.
  ///
  /// The method is MainActor-isolated with the context. It is intended for
  /// deterministic setup, not as a production write path or a way to mutate
  /// state concurrently with selectors, reactions, equality checks, or turns.
  ///
  /// - Parameters:
  ///   - valueReference: The exact manual descriptor-and-key state to seed.
  ///   - value: The candidate value, installed only when the source's equality
  ///     rule considers it changed.
  package func seedForTesting<Value>(
    _ valueReference: ManualCog<Value>,
    to value: Value
  ) {
    guard case .idle = turnPhase, arenaCore.isSettlementIdle, seedBarrierDepth == 0 else {
      fatalError("Cog seed can run only during idle test setup, outside a selector or reaction.")
    }

    seedBarrierDepth += 1
    defer { seedBarrierDepth -= 1 }

    let currentValue = arenaCore.manualValue(for: valueReference)
    guard !valueReference.descriptor.valuesAreEqual(currentValue, value) else { return }

    advanceRevision()
    arenaCore.publishTestingSeed(value, for: valueReference)
  }
}

#endif
