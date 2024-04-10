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

final class CogBox {
  final _boxedCogs = <BoxedCog>[];
  final _boxedMechanisms = <BoxedMechanism>[];
  final CogRegistry? _cogRegistry;
  final Cogtext _cogtext;
  final String? _debugLabel;
  final MechanismRegistry? _mechanismRegistry;

  CogBox(
    Cogtext cogtext, {
    CogRegistry? cogRegistry,
    String? debugLabel,
    MechanismRegistry? mechanismRegistry,
  })  : _cogRegistry = cogRegistry,
        _cogtext = cogtext,
        _debugLabel = debugLabel,
        _mechanismRegistry = mechanismRegistry;

  BoxedAutomaticCog<ValueType, SpinType> auto<ValueType, SpinType>(
    AutomaticCogDefinition<ValueType, SpinType> def, {
    Async? async,
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
    CogValueInitializer<ValueType>? init,
    Spin<SpinType>? spin,
    Duration? ttl,
  }) {
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

  void dispose() {
    for (final boxedMechanism in _boxedMechanisms) {
      _cogtext.runtime.disposeMechanism(boxedMechanism._mechanism.ordinal);

      boxedMechanism._isDisposed = true;
    }

    for (final boxedCog in _boxedCogs) {
      _cogtext.runtime.disposeCog(boxedCog._cog.ordinal);

      boxedCog._isDisposed = true;
    }

    _boxedCogs.clear();
    _boxedMechanisms.clear();
  }

  BoxedManualCog<ValueType, SpinType> man<ValueType, SpinType>(
    CogValueInitializer<ValueType> init, {
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
    Spin<SpinType>? spin,
  }) {
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

  BoxedMechanism mechanism(
    MechanismDefinition def, {
    String? debugLabel,
  }) {
    final mechanism = Mechanism(
      def,
      debugLabel: _maybeScopeDebugLabel(debugLabel),
      registry: _mechanismRegistry,
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
