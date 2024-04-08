import 'async.dart';
import 'common.dart';
import 'cog.dart';
import 'cog_registry.dart';
import 'mechanism.dart';
import 'mechanism_registry.dart';
import 'priority.dart';
import 'spin.dart';

final class CogBox {
  final _boxedCogs = <BoxedCog>[];
  final _boxedMechanisms = <BoxedMechanism>[];
  final Cogtext _cogtext;
  final String? _debugLabel;

  CogBox(Cogtext cogtext, {String? debugLabel})
      : _cogtext = cogtext,
        _debugLabel = debugLabel;

  BoxedAutomaticCog<ValueType, SpinType> auto<ValueType, SpinType>(
    AutomaticCogDefinition<ValueType, SpinType> def, {
    Async? async,
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
    CogValueInitializer<ValueType>? init,
    CogRegistry? registry,
    Spin<SpinType>? spin,
    Duration? ttl,
  }) {
    final cog = Cog.auto(
      def,
      async: async,
      debugLabel: _maybeScopeDebugLabel(debugLabel),
      eq: eq,
      init: init,
      registry: registry,
      spin: spin,
      ttl: ttl,
    );

    final boxedCog = BoxedAutomaticCog._(cog, this);

    _boxedCogs.add(boxedCog);

    return boxedCog;
  }

  void dispose() {
    for (final boxedMechanism in _boxedMechanisms) {
      _cogtext.runtime.disposeMechanism(boxedMechanism._mechanism.ordinal);
    }

    for (final boxedCog in _boxedCogs) {
      _cogtext.runtime.disposeCog(boxedCog._cog.ordinal);
    }

    _boxedCogs.clear();
    _boxedMechanisms.clear();
  }

  BoxedManualCog<ValueType, SpinType> man<ValueType, SpinType>(
    CogValueInitializer<ValueType> init, {
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
    CogRegistry? registry,
    Spin<SpinType>? spin,
  }) {
    final cog = Cog.man(
      init,
      debugLabel: _maybeScopeDebugLabel(debugLabel),
      eq: eq,
      registry: registry,
      spin: spin,
    );

    final boxedCog = BoxedManualCog._(cog, this);

    _boxedCogs.add(boxedCog);

    return boxedCog;
  }

  BoxedMechanism mechanism(
    MechanismDefinition def, {
    String? debugLabel,
    MechanismRegistry? registry,
  }) {
    final mechanism = Mechanism(
      def,
      debugLabel: _maybeScopeDebugLabel(debugLabel),
      registry: registry,
    );

    final boxedMechanism = BoxedMechanism(this, mechanism);

    _boxedMechanisms.add(boxedMechanism);

    return boxedMechanism;
  }

  String? _maybeScopeDebugLabel(String? debugLabel) {
    if (_debugLabel == null || debugLabel == null) {
      return null;
    }

    return '$_debugLabel::$debugLabel';
  }
}

final class BoxedAutomaticCog<ValueType, SpinType>
    extends BoxedCog<ValueType, SpinType> {
  @override
  final AutomaticCog<ValueType, SpinType> _cog;

  @override
  final CogBox _cogBox;

  BoxedAutomaticCog._(this._cog, this._cogBox);

  @override
  Stream<ValueType> watch({
    Priority? priority,
    SpinType? spin,
  }) =>
      _cog.watch(_cogBox._cogtext, priority: priority, spin: spin);
}

sealed class BoxedCog<ValueType, SpinType> {
  Cog<ValueType, SpinType> get _cog;

  CogBox get _cogBox;

  ValueType read({SpinType? spin}) => _cog.read(_cogBox._cogtext, spin: spin);

  Stream<ValueType> watch({
    Priority? priority,
    SpinType? spin,
  }) =>
      _cog.watch(_cogBox._cogtext, priority: priority, spin: spin);
}

final class BoxedManualCog<ValueType, SpinType>
    extends BoxedCog<ValueType, SpinType> {
  @override
  final ManualCog<ValueType, SpinType> _cog;

  @override
  final CogBox _cogBox;

  BoxedManualCog._(this._cog, this._cogBox);
}

final class BoxedMechanism {
  final CogBox _cogBox;

  final Mechanism _mechanism;

  BoxedMechanism(this._cogBox, this._mechanism);

  void pause() {
    _mechanism.pause(_cogBox._cogtext);
  }

  void resume(Cogtext cogtext) {
    _mechanism.resume(_cogBox._cogtext);
  }
}
