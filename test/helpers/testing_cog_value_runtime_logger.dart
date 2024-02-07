import 'package:cog/cog.dart';
import 'package:logging/logging.dart';

final class TestingCogValueRuntimeLogger implements CogValueRuntimeLogging {
  final _logger = Logger('TestingCogValueRuntimeLogger');

  @override
  void debug(CogValue? cogValue, String message, [Object? details]) {
    if (isEnabled) {
      _log(
        cogValue: cogValue,
        error: details,
        level: Level.FINEST,
        message: message,
        stackTrace: null,
      );
    }
  }

  @override
  void error(
    CogValue? cogValue,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (isEnabled) {
      _log(
        cogValue: cogValue,
        error: error,
        level: Level.SEVERE,
        message: message,
        stackTrace: stackTrace,
      );
    }
  }

  void _log({
    required CogValue? cogValue,
    required Object? error,
    required Level level,
    required String message,
    required StackTrace? stackTrace,
  }) {
    final stringBuffer = StringBuffer();

    if (cogValue != null) {
      stringBuffer
        ..writeCogValueDebugTagOf(cogValue)
        ..write(' ');
    }

    stringBuffer.write(message);

    _logger.log(
      level,
      stringBuffer.toString(),
      error,
      stackTrace,
    );
  }

  @override
  bool get isEnabled => Logger.root.level <= Level.FINEST;
}

extension on StringBuffer {
  void writeCogValueDebugTagOf(CogValue cogValue) {
    write('[');

    final cog = cogValue.cog;

    if (cog.debugLabel != null) {
      write(cog.debugLabel);
      write('<');
      write(cog.ordinal);
      write('>');
    } else {
      write(cog.ordinal);
    }

    write('::');

    final spin = cogValue.spinOrNull;

    if (spin != null) {
      write(spin);
      write('<');
      write(cogValue.ordinal);
      write('>');
    } else {
      write(cogValue.ordinal);
    }

    write(']');
  }
}
