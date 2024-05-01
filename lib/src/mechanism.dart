import 'dart:async';

import 'cog.dart';
import 'common.dart';
import 'mechanism_registry.dart';
import 'priority.dart';

part 'mechanism_controller.dart';

/// [Mechanism] enables side effects that observe, read from or write to the
/// [Cog] state graph.
///
/// {@template mechanism.blurb}
/// Mechanisms work by invoking [def] once for every active [Cogtext]. In fact,
/// following the instantiation of a new [Mechanism] while an active [Cogtext]
/// exists, [def] is invoked almost immediately. The [def] function can
/// ergonomically interface with Cogs using the [MechanismController] passed as
/// its only argument as a [Cogtext].
/// ```dart
/// Mechanism((m) {
///   final number = numberCog.read(m);
///
///   numberCog.write(m, number + 1);
///
///   final subscription = numberCog.watch(m, (number) {
///     print('new number is $number!');
///   });
///
///   m.onDispose(subscription.cancel);
/// });
/// ```
/// {@endtemplate}
///
/// Notice that disposal callbacks can be wired up to the [Mechanism] using
/// [MechanismController.onDispose]. This way, when a [Mechanism] is disposed,
/// its [def] closure doesn't spring a leak.
///
/// Because watching Cogs is such a common [Mechanism] use case,
/// [MechanismController] also exposes a helper called
/// [MechanismController.onChange] to make tracking Cog value changes and
/// auto-disposing the listener easy.
/// ```dart
/// Mechanism((m) {
///   m.onChange(numberCog, (number) {
///     print('new number is $number!');
///   });
/// });
/// ```
///
/// Sometimes it is necessary to disable the effects of a [Mechanism] after it
/// has been created. Using [Mechanism.pause] and [Mechanism.resume], you can
/// precisely control when a [Mechanism] is active.
/// ```dart
/// final myMechanism = Mechanism((m) {
///   final timer = Timer.periodic(Duration(seconds: 1), (_) {
///     print('1 second passed');
///   });
///
///   m.onDispose(timer.cancel);
/// });
///
/// myMechanism.pause();  // Printing stops.
/// myMechanism.resume(); // Printing resumes.
/// ```
final class Mechanism {
  /// Optional description of the side-effect encapsulated by this [Mechanism].
  ///
  /// This label is used by logging and development tools to make understanding
  /// the application state machine easier.
  String? debugLabel;

  /// Stipulates the behaviors and configuration of the side effect encapsulated
  /// by this [Mechanism].
  ///
  /// For more information, see the [Mechanism] docs.
  final MechanismDefinition def;

  /// Integer that uniquely identifies this [Mechanism] relative to all other
  /// Mechanisms registered with the presiding [MechanismRegistry].
  late final MechanismOrdinal ordinal;

  /// Creates a new [Mechanism].
  ///
  /// {@macro mechanism.blurb}
  ///
  /// {@template mechanism.constructor}
  /// * [def] stipulates the behaviors and configuration of the side effect to
  ///   be encapsulated by the resulting [Mechanism]
  /// * [debugLabel] is the optional description of the side-effect encapsulated
  ///   by the resulting [Mechanism]
  /// * [registry] is the [MechanismRegistry] with which the resulting
  ///   [Mechanism] will be registered upon instantiation - defaults to
  ///   [GlobalMechanismRegistry]
  /// {@endtemplate}
  Mechanism(
    this.def, {
    this.debugLabel,
    MechanismRegistry? registry,
  }) {
    registry ??= GlobalMechanismRegistry.instance;

    ordinal = registry.register(this);
  }

  /// Temporarily halts the functioning of this [Mechanism] within the specified
  /// [Cogtext].
  ///
  /// While a [Mechanism] is paused, it is functionally dormant - almost as if
  /// it was never created at all. Mechanisms may be "unpaused" with the
  /// [resume] method.
  void pause(Cogtext cogtext) {
    cogtext.runtime.pauseMechanism(ordinal);
  }

  /// Reverses the effects of a call to [pause] within the specified [Cogtext],
  /// re-instating this [Mechanism] to a state of full functionality.
  ///
  /// This method does nothing if this [Mechanism] is not paused within
  /// specified [Cogtext].
  void resume(Cogtext cogtext) {
    cogtext.runtime.resumeMechanism(ordinal);
  }

  @override
  String toString() => 'Mechanism('
      '${debugLabel != null ? 'debugLabel: "$debugLabel"' : ''}'
      ')';
}

/// Closure that stipulates the behaviors and configuration of the side effect
/// encapsulated by a [Mechanism].
///
/// For more information, see the [Mechanism] docs.
typedef MechanismDefinition = void Function(MechanismController);
