import 'async.dart';
import 'common.dart';
import 'cog.dart';
import 'cog_registry.dart';
import 'cog_runtime.dart';
import 'cog_state.dart';
import 'mechanism.dart';
import 'mechanism_registry.dart';
import 'priority.dart';
import 'spin.dart';

part 'boxed_cog.dart';
part 'boxed_mechanism.dart';

/// Abstraction designed to group and scope related Cogs and Mechanisms.
///
/// [CogBox] ensures that any Cogs or Mechanisms created against it all use the
/// same surrounding [Cogtext], can be disposed as a group with [dispose], and
/// are labeled for debugging in a similar way.
///
/// [CogBox] is best used as a way to create Cogs and Mechanisms that "belong"
/// to an ephemeral entity. For example, in a graphical application that
/// features a canvas on which shapes can placed and manipulated, it would make
/// sense to give every shape a [CogBox] to contain its Cogs tracking position,
/// rotation, and size. By using [CogBox], global state that generalizes over
/// shape state doesn't need to lean too heavily on [Spin].
final class CogBox {
  /// Optional description of the scope or domain represented by this [CogBox].
  ///
  /// This label is used by logging and development tools to make understanding
  /// the application state machine easier.
  final String? debugLabel;

  /// List of all Cogs created within this [CogBox].
  final _boxedCogs = <BoxedCog>[];

  /// List of all Mechanisms created within this [CogBox].
  final _boxedMechanisms = <BoxedMechanism>[];

  /// [CogRegistry] with which the Cogs created by this [CogBox] are
  /// registered upon instantiation.
  ///
  /// Defaults to [GlobalCogRegistry].
  final CogRegistry? _cogRegistry;

  /// [Cogtext] to which the Cogs and Mechanisms created by this [CogBox] are
  /// bound.
  final Cogtext _cogtext;

  /// `true` if this [CogBox] has been disposed.
  var _isDisposed = false;

  /// [MechanismRegistry] with which the Mechanisms created by this [CogBox] are
  /// registered upon instantiation.
  ///
  /// Defaults to [GlobalMechanismRegistry].
  final MechanismRegistry? _mechanismRegistry;

  /// Creates a new [CogBox].
  ///
  /// * [cogtext] is the [Cogtext] to which the Cogs and Mechanisms created by
  ///   the resulting [CogBox] will be bound
  /// * [cogRegistry] is the [CogRegistry] with which the Cogs created by the
  ///   resulting [CogBox] will be registered upon instantiation - defaults to
  ///   [GlobalCogRegistry]
  /// * [debugLabel] is the optional description of the scope or domain
  ///   represented by the resulting [CogBox]
  /// * [mechanismRegistry] is the [MechanismRegistry] with which the Mechanisms
  ///   created by the resulting [CogBox] will be registered upon instantiation
  ///   - defaults to [GlobalMechanismRegistry]
  CogBox(
    Cogtext cogtext, {
    CogRegistry? cogRegistry,
    this.debugLabel,
    MechanismRegistry? mechanismRegistry,
  })  : _cogRegistry = cogRegistry,
        _cogtext = cogtext,
        _mechanismRegistry = mechanismRegistry;

  /// Creates a new automatic Cog belonging to this [CogBox].
  ///
  /// {@macro cog.auto.constructor}
  BoxedAutomaticCog<ValueType, SpinType> auto<ValueType, SpinType>(
    AutomaticCogDefinition<ValueType, SpinType> def, {
    Async? async,
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
    CogValueInitializer<ValueType>? init,
    Spin<SpinType>? spin,
    Duration? ttl,
  }) {
    assert(_notDisposed());

    final cog = Cog.auto(
      def,
      async: async,
      debugLabel: _maybeScopeDebugLabel(debugLabel),
      eq: eq,
      init: init,
      registry: _cogRegistry,
      spin: spin,
      ttl: ttl,
    );

    final boxedCog = BoxedAutomaticCog._(cog, this);

    _boxedCogs.add(boxedCog);

    return boxedCog;
  }

  /// Halts and destroys all Cogs and Mechanisms that belong to this [CogBox].
  void dispose() {
    if (_isDisposed) {
      return;
    }

    for (final boxedMechanism in _boxedMechanisms) {
      _cogtext.runtime.disposeMechanism(boxedMechanism._mechanism.ordinal);
    }

    for (final boxedCog in _boxedCogs) {
      _cogtext.runtime.disposeCog(boxedCog._cog.ordinal);
    }

    _boxedCogs.clear();
    _boxedMechanisms.clear();

    _isDisposed = true;
  }

  /// Creates a new manual Cog belonging to this [CogBox].
  ///
  /// {@macro cog.man.constructor}
  BoxedManualCog<ValueType, SpinType> man<ValueType, SpinType>(
    CogValueInitializer<ValueType> init, {
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
    Spin<SpinType>? spin,
  }) {
    assert(_notDisposed());

    final cog = Cog.man(
      init,
      debugLabel: _maybeScopeDebugLabel(debugLabel),
      eq: eq,
      registry: _cogRegistry,
      spin: spin,
    );

    final boxedCog = BoxedManualCog._(cog, this);

    _boxedCogs.add(boxedCog);

    return boxedCog;
  }

  /// Creates a new [Mechanism] belonging to this [CogBox].
  ///
  /// {@macro mechanism.blurb}
  ///
  /// {@macro mechanism.constructor}
  BoxedMechanism mechanism(
    MechanismDefinition def, {
    String? debugLabel,
  }) {
    assert(_notDisposed());

    final mechanism = Mechanism(
      def,
      debugLabel: _maybeScopeDebugLabel(debugLabel),
      registry: _mechanismRegistry,
    );

    final boxedMechanism = BoxedMechanism._(this, mechanism);

    _boxedMechanisms.add(boxedMechanism);

    return boxedMechanism;
  }

  @override
  String toString() => 'CogBox('
      '${debugLabel != null ? 'debugLabel: "$debugLabel"' : ''}'
      ')';

  /// Combines this [CogBox]'s [CogBox.debugLabel] with the specified
  /// [debugLabel], returning `null` if combination is not possible.
  String? _maybeScopeDebugLabel(String? debugLabel) {
    if (this.debugLabel == null || debugLabel == null) {
      return null;
    }

    return '${this.debugLabel}::$debugLabel';
  }

  /// Method used to in `assert`s to ensure that this [BoxedCog] has not yet
  /// been disposed.
  bool _notDisposed() {
    if (_isDisposed) {
      throw StateError('$this has been disposed');
    }

    return true;
  }
}
