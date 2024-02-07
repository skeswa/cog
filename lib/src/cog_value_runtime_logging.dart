import 'cog_value.dart';

abstract interface class CogValueRuntimeLogging {
  void debug(CogValue? cogValue, String message, [Object? details]);

  void error(CogValue? cogValue, String message,
      [Object? error, StackTrace? stackTrace]);

  bool get isEnabled;
}

final class NoOpCogValueRuntimeLogging implements CogValueRuntimeLogging {
  const NoOpCogValueRuntimeLogging();

  @override
  void debug(CogValue? cogValue, String message, [Object? details]) {}

  @override
  void error(
    CogValue? cogValue,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {}

  @override
  bool get isEnabled => false;
}
