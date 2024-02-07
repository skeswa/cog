import 'dart:async';

import 'package:cog/src/notification_urgency.dart';

import 'common.dart';
import 'cog_registry.dart';
import 'cog_value_runtime.dart';
import 'cogtime.dart';
import 'spin.dart';

part 'automatic_cog.dart';
part 'cogtext.dart';
part 'manual_cog.dart';

sealed class Cog<ValueType, SpinType> {
  String? debugLabel;

  final CogValueComparator<ValueType> eq;

  final CogValueInitializer<ValueType> init;

  late final CogOrdinal ordinal;

  final Spin<SpinType>? spin;

  factory Cog(
    AutomaticCogDefinition<ValueType, SpinType> def, {
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
    required CogValueInitializer<ValueType> init,
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
    CogValueInitializer<ValueType> init, {
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
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

    final cogValue = cogtext._cogValueRuntime.acquire(cog: this, cogSpin: spin);

    return cogValue.value;
  }

  Stream<ValueType> watch(
    Cogtext cogtext, {
    SpinType? spin,
    NotificationUrgency urgency = NotificationUrgency.notUrgent,
  }) {
    _assertThatSpinMatches(spin);

    return cogtext._cogValueRuntime.acquireValueChangeStream(
      cog: this,
      cogSpin: spin,
      urgency: urgency,
    );
  }

  void _assertThatSpinMatches(SpinType? spin) {
    assert(() {
      if (this.spin == null && spin != null) {
        throw ArgumentError(
          'Cannot read with spin from a Cog that '
          'does not specify a spin in its definition',
        );
      }

      if (this.spin != null && spin == null) {
        throw ArgumentError(
          'Cannot read without spin from a Cog that '
          'does specifies a spin in its definition',
        );
      }

      return true;
    }());
  }
}
