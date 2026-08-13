extension Cogtext {
  /// Runs an async cog's selector and work again even when no dependency changed.
  ///
  /// Under `.latest`, refresh replaces any in-flight work. The refreshed phase
  /// follows the same pending, generation, and result rules as a dependency-
  /// triggered reload.
  public func refresh<Value>(_ valueReference: AsyncCog<Value>) {
    asyncState(for: valueReference).refresh(in: self)
  }
}
