part of 'cog.dart';

final class Cogtext {
  final CogRuntime runtime;

  Cogtext({CogRuntime? cogRuntime})
      : runtime = cogRuntime ?? StandardCogRuntime();

  Future<void> dispose() => runtime.dispose();
}
