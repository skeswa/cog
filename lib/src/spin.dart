final class Spin<SpinType> {
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
