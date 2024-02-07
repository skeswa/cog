import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void setUpLogging([Level level = Level.ALL]) {
  setUpAll(() {
    Logger.root
      ..level = Level.ALL
      ..onRecord.listen((record) {
        final message = '[${record.level.name}] '
            '${record.loggerName} @${record.time}: '
            '${record.message}'
            '${record.error != null ? ': ${record.error}' : ''}'
            '${record.stackTrace != null ? '\n${record.stackTrace}' : ''}';

        // ignore: avoid_print
        print(message);
      });
  });
}
