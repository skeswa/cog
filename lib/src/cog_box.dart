import 'async.dart';
import 'common.dart';
import 'cog.dart';
import 'cog_registry.dart';
import 'mechanism.dart';
import 'mechanism_registry.dart';
import 'priority.dart';
import 'spin.dart';

part 'boxed_cog.dart';
part 'boxed_mechanism.dart';

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

    final boxedMechanism = BoxedMechanism._(this, mechanism);

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
