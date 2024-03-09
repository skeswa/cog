import 'package:cog/cog.dart';

final class NoOpCogRuntime implements CogRuntime {
  const NoOpCogRuntime();

  @override
  noSuchMethod(Invocation invocation) => null;
}
