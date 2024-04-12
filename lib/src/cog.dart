import 'dart:async';

import 'async.dart';
import 'common.dart';
import 'cog_registry.dart';
import 'cog_runtime.dart';
import 'cog_state.dart';
import 'priority.dart';
import 'standard_cog_runtime.dart';
import 'spin.dart';

part 'automatic_cog.dart';
part 'automatic_cog_controller.dart';
part 'cog_like.dart';
part 'cogtext.dart';
part 'manual_cog.dart';

/// [Cog] is an abstraction that imbues application state with composability,
/// observability, and reliability.
///
/// Cogs are designed to organize evolving, related data such that operating on
/// it is akin to turning "interlocking cogs in a machine": The connections
/// between related data should be explicit and easily understandable. Applying
/// mutations to this data should be both ergonomic and trustworthy.
///
/// There are exactly two kinds of [Cog]:
/// - **Automatic**\
///   Automatic Cogs, created with the default `Cog(...)` constructor, derive
///   their value by composing the values of other Cogs and/or external state.
///   In practice, most Cogs should be automatic.
/// - **Manual**\
///   Manual Cogs are assigned values imperatively with the `write(...)` method.
///   These Cogs, created with the `Cog.man(...)` constructor, are intended to
///   be roots of the state graph, and should be used sparingly.
///
/// Automatic and manual combine to form a reactive state graph robust enough
/// for applications spanning the full spectrum of complexity.
///
/// {@macro cog_like.spin}
sealed class Cog<ValueType, SpinType> implements CogLike<ValueType, SpinType> {
  @override
  String? debugLabel;

  @override
  final CogValueComparator<ValueType>? eq;

  @override
  late final CogOrdinal ordinal;

  @override
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
      auto(
        def,
        async: async,
        debugLabel: debugLabel,
        eq: eq,
        init: init,
        registry: registry,
        spin: spin,
        ttl: ttl,
      );

  static AutomaticCog<ValueType, SpinType> auto<ValueType, SpinType>(
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
        spin: spin,
      );

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

    final cogState = cogtext.runtime.acquire(cog: this, cogSpin: spin);

    return cogState.evaluate();
  }

  Stream<ValueType> watch(
    Cogtext cogtext, {
    Priority? priority,
    SpinType? spin,
  }) {
    assert(thatSpinsMatch(this, spin));

    final cogState = cogtext.runtime.acquire(cog: this, cogSpin: spin);

    return cogtext.runtime.acquireValueChangeStream(
      cogState: cogState,
      priority: priority ?? Priority.normal,
    );
  }
}
