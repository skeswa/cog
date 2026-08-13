extension Cogtext {
  /// Runs an async cog's selector and work again even when no dependency changed.
  ///
  /// Refresh enters the normal async settlement path. The selector reads its
  /// synchronous dependencies again, and pending, success, or failure is
  /// published in the same separate named turns as a dependency-triggered
  /// reload. Under `.latest`, the call cancels in-flight work and advances the
  /// generation before starting its replacement, so a late old result cannot
  /// publish.
  ///
  /// A never-read reference performs one initial load; it is not initialized
  /// and then immediately replaced. Refresh itself is one-shot demand: it adds
  /// neither a dependency edge nor an Observation boundary. If no reaction
  /// lease or UI boundary already keeps the exact state observed, the call
  /// starts or renews its ordinary `whileObserved` grace after selecting the
  /// work. An internal selector edge may defer removal at expiry, but it is not
  /// durable observation and does not earn another grace window.
  ///
  /// Call refresh from event handling or a reaction. Calling it while any
  /// derived or async selector is computing traps before the target state is
  /// created, using the same diagnostic as a commit during derivation.
  ///
  /// - Parameter valueReference: The async value to load again.
  public func refresh<Value>(_ valueReference: AsyncCog<Value>) {
    requireOutsideDerivedComputation(forTurnNamed: #function)
    let state = asyncState(for: valueReference)
    state.refresh(in: self)
    scheduleLifetimeReleaseIfUnobserved(state)
  }
}
