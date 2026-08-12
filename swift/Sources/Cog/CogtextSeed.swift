#if DEBUG

extension Cogtext {
  /// Seeds a manual source for deterministic test setup.
  ///
  /// Seeding is the debug-only exception to ordinary turn-based writes. It
  /// applies the source's equality rule and marks dependent cogs for later
  /// settlement, but opens no turn and computes nothing eagerly. Feature state
  /// files should wrap `fileprivate` sources in narrow test helpers. Seed only
  /// while the context is idle; seeding during graph work would break its
  /// snapshot.
  ///
  /// - Parameters:
  ///   - valueReference: The manual source to seed.
  ///   - value: The candidate value, installed only when the source's equality
  ///     rule considers it changed.
  public func seed<Value>(_ valueReference: ManualCog<Value>, to value: Value) {
    guard case .idle = turnPhase, trackedConsumer == nil, seedBarrierDepth == 0 else {
      fatalError("Cog seed can run only during idle test setup, outside a selector or reaction.")
    }

    seedBarrierDepth += 1
    defer { seedBarrierDepth -= 1 }

    let state = manualState(for: valueReference)
    guard !state.descriptor.valuesAreEqual(state.currentValue, value) else { return }

    let revision = advanceRevision()
    state.currentValue = value
    state.markChanged(at: revision)
    state.observationBoundary?.deferChange()
    invalidateSubscribers(of: state)
  }
}

#endif
