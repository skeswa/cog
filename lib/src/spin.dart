/// Helper class used purely to specify the [SpinType] of a Cog.
///
/// {@macro cog_like.spin}
final class Spin<SpinType> {
  /// Creates a new [Spin] that does nothing except specify [SpinType].
  ///
  /// This constructor throws if [SpinType] is left unspecified. In this case,
  /// a `dynamic` [SpinType] is assumed to be an unspecified [SpinType].
  Spin() {
    assert(() {
      if (SpinType == dynamic) {
        throw ArgumentError(
          'The T in Spin<T> must not be dynamic - a type must be specified',
        );
      }

      return true;
    }());
  }
}
