import 'dart:async';

import 'common.dart';
import 'cog_registry.dart';
import 'cog_state_runtime.dart';
import 'notification_urgency.dart';
import 'standard_cog_state_runtime.dart';
import 'spin.dart';

part 'automatic_cog.dart';
part 'cogtext.dart';
part 'manual_cog.dart';

sealed class Cog<ValueType, SpinType> {
  String? debugLabel;

  final CogStateComparator<ValueType> eq;

  final CogStateInitializer<ValueType> init;

  late final CogOrdinal ordinal;

  final Spin<SpinType>? spin;

  factory Cog(
    AutomaticCogDefinition<ValueType, SpinType> def, {
    String? debugLabel,
    CogStateComparator<ValueType>? eq,
    required CogStateInitializer<ValueType> init,
    CogRegistry? registry,
    Spin<SpinType>? spin,
    Duration? ttl,
  }) =>
      AutomaticCog._(
        def,
        debugLabel: debugLabel,
        eq: eq,
        init: init,
        registry: registry,
        spin: spin,
        ttl: ttl,
      );

  static ManualCog<ValueType, SpinType> man<ValueType, SpinType>(
    CogStateInitializer<ValueType> init, {
    String? debugLabel,
    CogStateComparator<ValueType>? eq,
    CogRegistry? registry,
    Spin<SpinType>? spin,
  }) =>
      ManualCog._(
          debugLabel: debugLabel,
          eq: eq,
          init: init,
          registry: registry,
          spin: spin);

  Cog._({
    required this.debugLabel,
    required this.eq,
    required this.init,
    required CogRegistry? registry,
    required this.spin,
  }) {
    ordinal = (registry ?? GlobalCogRegistry.instance).register(this);
  }

  ValueType read(
    Cogtext cogtext, {
    SpinType? spin,
  }) {
    _assertThatSpinMatches(spin);

    final cogState = cogtext._cogStateRuntime.acquire(cog: this, cogSpin: spin);

    return cogState.value;
  }

  Stream<ValueType> watch(
    Cogtext cogtext, {
    SpinType? spin,
    NotificationUrgency urgency = NotificationUrgency.lessUrgent,
  }) {
    _assertThatSpinMatches(spin);

    return cogtext._cogStateRuntime.acquireValueChangeStream(
      cog: this,
      cogSpin: spin,
      urgency: urgency,
    );
  }

  void _assertThatSpinMatches(SpinType? spin) {
    assert(() {
      if (this.spin == null && spin != null) {
        throw ArgumentError(
          'Cannot read or watch a Cog with spin that '
          'does not specify a spin in its definition',
        );
      }

      if (this.spin != null && spin == null) {
        throw ArgumentError(
          'Cannot read or watch a Cog without spin that '
          'specifies a spin in its definition',
        );
      }

      return true;
    }());
  }
}
