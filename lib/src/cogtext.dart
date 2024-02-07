part of 'cog.dart';

final class Cogtext {
  final CogValueRuntime _cogValueRuntime;

  Cogtext({CogValueRuntime? cogValueRuntime})
      : _cogValueRuntime = cogValueRuntime ?? Cogtime();
}
