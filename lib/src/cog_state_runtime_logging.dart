abstract interface class CogStateRuntimeLogging {
  void debug(
    Object? cogStateOrCogStateOrdinal,
    String message, [
    Object? details,
  ]);

  void error(
    Object? cogStateOrCogStateOrdinal,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]);
}

final class NoOpCogStateRuntimeLogging implements CogStateRuntimeLogging {
  const NoOpCogStateRuntimeLogging();

  @override
  void debug(
    Object? cogStateOrCogStateOrdinal,
    String message, [
    Object? details,
  ]) {}

  @override
  void error(
    Object? cogStateOrCogStateOrdinal,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {}
}
