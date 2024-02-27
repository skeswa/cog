extension NullTypeExtension on Null {
  T? Function() init<T>() {
    assert(() {
      if (T == dynamic) {
        throw ArgumentError(
          'The T in null.init<T>() must not be dynamic - '
          'a type must be specified',
        );
      }

      return true;
    }());

    return () => null;
  }
}
