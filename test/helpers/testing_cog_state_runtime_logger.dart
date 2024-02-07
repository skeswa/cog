import 'package:cog/cog.dart';
import 'package:logging/logging.dart';

final class TestingCogStateRuntimeLogger implements CogStateRuntimeLogging {
  final _logger = Logger('TestingCogStateRuntimeLogger');

  @override
  void debug(
    Object? cogStateOrCogStateOrdinal,
    String message, [
    Object? details,
  ]) =>
      _log(
        cogStateOrCogStateOrdinal: cogStateOrCogStateOrdinal,
        error: details,
        level: Level.FINEST,
        message: message,
        stackTrace: null,
      );

  @override
  void error(
    Object? cogStateOrCogStateOrdinal,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) =>
      _log(
        cogStateOrCogStateOrdinal: cogStateOrCogStateOrdinal,
        error: error,
        level: Level.SEVERE,
        message: message,
        stackTrace: stackTrace,
      );

  void _log({
    required Object? cogStateOrCogStateOrdinal,
    required Object? error,
    required Level level,
    required String message,
    required StackTrace? stackTrace,
  }) {
    if (Logger.root.level > level) {
      return;
    }

    final stringBuffer = StringBuffer();

    if (cogStateOrCogStateOrdinal is CogState) {
      stringBuffer
        ..writeCogStateDebugTagOf(cogStateOrCogStateOrdinal)
        ..write(' ');
    } else if (cogStateOrCogStateOrdinal is CogStateOrdinal) {
      stringBuffer
        ..writeCogStateOrdinalDebugTagOf(cogStateOrCogStateOrdinal)
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
}

extension on StringBuffer {
  void writeCogStateDebugTagOf(CogState cogState) {
    write('[');

    final cog = cogState.cog;

    if (cog.debugLabel != null) {
      write(cog.debugLabel);
      write('<');
      write(cog.ordinal);
      write('>');
    } else {
      write(cog.ordinal);
    }

    write('::');

    final spin = cogState.spinOrNull;

    if (spin != null) {
      write(spin);
      write('<');
      write(cogState.ordinal);
      write('>');
    } else {
      write(cogState.ordinal);
    }

    write(']');
  }

  void writeCogStateOrdinalDebugTagOf(CogStateOrdinal cogStateOrdinal) {
    write('[?::');
    write(cogStateOrdinal);
    write(']');
  }
}
