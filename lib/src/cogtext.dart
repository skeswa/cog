part of 'cog.dart';

class Cogtext {
  final CogRuntime runtime;

  Cogtext({CogRuntime? cogRuntime})
      : runtime = cogRuntime ?? StandardCogRuntime();

  FutureOr<void> dispose() => runtime.dispose();
}
