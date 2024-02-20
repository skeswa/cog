import 'dart:async';

import 'async.dart';
import 'common.dart';
import 'cog_registry.dart';
import 'cog_state_runtime.dart';
import 'priority.dart';
import 'standard_cog_state_runtime.dart';
import 'spin.dart';

part 'automatic_cog.dart';
part 'cogtext.dart';
part 'manual_cog.dart';

sealed class Cog<ValueType, SpinType> {
  String? debugLabel;

  final CogValueComparator<ValueType> eq;

  late final CogOrdinal ordinal;

  final Spin<SpinType>? spin;

  factory Cog(
    AutomaticCogDefinition<ValueType, SpinType> def, {
    Async? async,
    String? debugLabel,
    CogValueComparator<ValueType>? eq,
    CogValueInitializer<ValueType>? init,
    CogRegistry? registry,
    Spin<SpinType>? spin,
    Duration? ttl,
  }) =>
      AutomaticCog._(
        def,
        async: async,
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
    required CogRegistry? registry,
    required this.spin,
  }) {
    ordinal = (registry ?? GlobalCogRegistry.instance).register(this);
  }

  ValueType read(
    Cogtext cogtext, {
    SpinType? spin,
  }) {
    assert(thatSpinsMatch(this, spin));

    final cogState = cogtext._cogStateRuntime.acquire(cog: this, cogSpin: spin);

    return cogState.evaluate();
  }

  Stream<ValueType> watch(
    Cogtext cogtext, {
    Priority priority = Priority.low,
    SpinType? spin,
  }) {
    assert(thatSpinsMatch(this, spin));

    final cogState = cogtext._cogStateRuntime.acquire(cog: this, cogSpin: spin);

    return cogtext._cogStateRuntime.acquireValueChangeStream(
      cogState: cogState,
      priority: priority,
    );
  }
}
