part of 'cog.dart';

/// Environment that keeps track of the values and lifecycles of Cogs and
/// Mechanisms for a particular purpose or context.
///
/// At least one [Cogtext] is required for Cogs and Mechanisms to function
/// correctly. Typically, one single [Cogtext] is defined for each application
/// or library user.
class Cogtext {
  /// Optional description of the state wrapped by this [Cog].
  ///
  /// This label is used by logging and development tools to make understanding
  /// the application state machine easier.
  final String? debugLabel;

  /// [CogRuntime] powering this [Cogtext].
  final CogRuntime runtime;

  /// Creates a new [Cogtext].
  ///
  /// * [cogRuntime] is the instance of [CogRuntime] that should be wrapped by
  ///   the resulting [Cogtext] - defaults to a new instance of
  ///   [StandardCogRuntime]
  /// * [debugLabel] is the optional description of the side-effect encapsulated
  ///   by the resulting [Cogtext]
  Cogtext({CogRuntime? cogRuntime, this.debugLabel})
      : runtime = cogRuntime ?? StandardCogRuntime();

  /// Halts the [runtime] underlying this [Cogtext], destroying all of its state
  /// and cancelling all of its subscriptions.
  FutureOr<void> dispose() => runtime.dispose();

  @override
  String toString() => 'Cogtext('
      '${debugLabel != null ? 'debugLabel: "$debugLabel"' : ''}'
      ')';
}
