#if DEBUG

extension Cogtext {
  /// Seeds a manual source for deterministic test setup.
  ///
  /// Seeding is the debug-only exception to ordinary turn-based writes. It
  /// applies the source's equality rule and marks dependent cogs for later
  /// settlement, but opens no turn and computes nothing eagerly. Feature state
  /// files wrap their `fileprivate` sources in narrow helpers rather than
  /// publishing those value references to tests. Use it only between graph runs; changing
  /// state during a turn, selector, reaction, or equality check cannot preserve
  /// that operation's consistent snapshot.
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
    invalidateSubscribers(of: state)
  }
}

#endif
