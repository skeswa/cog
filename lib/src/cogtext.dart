part of 'cog.dart';

final class Cogtext {
  final CogStateRuntime _cogStateRuntime;

  Cogtext({CogStateRuntime? cogStateRuntime})
      : _cogStateRuntime = cogStateRuntime ?? StandardCogStateRuntime();

  Future<void> dispose() => _cogStateRuntime.dispose();
}
