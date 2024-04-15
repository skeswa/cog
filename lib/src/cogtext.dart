part of 'cog.dart';

class Cogtext {
  /// Optional description of the state wrapped by this [Cog].
  ///
  /// This label is used by logging and development tools to make understanding
  /// the application state graph easier.
  final String? debugLabel;

  /// [CogRuntime] powering this [Cogtext].
  final CogRuntime runtime;

  Cogtext({CogRuntime? cogRuntime, this.debugLabel})
      : runtime = cogRuntime ?? StandardCogRuntime();

  FutureOr<void> dispose() => runtime.dispose();
}
