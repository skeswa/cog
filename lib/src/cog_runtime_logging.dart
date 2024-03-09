abstract interface class CogRuntimeLogging {
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

final class NoOpCogRuntimeLogging implements CogRuntimeLogging {
  const NoOpCogRuntimeLogging();

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
