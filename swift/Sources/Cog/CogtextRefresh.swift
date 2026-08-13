extension Cogtext {
  /// Runs an async cog's selector and work again even when no dependency changed.
  ///
  /// Under `.latest`, refresh replaces any in-flight work. The refreshed phase
  /// follows the same pending, generation, and result rules as a dependency-
  /// triggered reload. Refreshing a never-read reference starts its initial
  /// work exactly once rather than initializing and replacing it.
  ///
  /// Refresh installs no durable consumer. When no consumer already exists,
  /// the call starts or renews ordinary `whileObserved` grace.
  /// Calling refresh during derived computation traps before creating target state.
  public func refresh<Value>(_ valueReference: AsyncCog<Value>) {
    requireOutsideDerivedComputation(forTurnNamed: #function)
    let state = asyncState(for: valueReference)
    state.refresh(in: self)
    scheduleLifetimeReleaseIfUnobserved(state)
  }
}
