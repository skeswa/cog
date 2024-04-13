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
///   their values by composing and manipulating the values of other Cogs and/or
///   external state. In practice, most Cogs should be automatic.
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

  /// {@macro cog.auto.constructor}
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

  /// {@template cog.auto.constructor}
  /// Creates a new automatic [Cog].
  ///
  /// Automatic Cogs derive their values by composing and manipulating the
  /// values of other Cogs and/or external state. At its core, an automatic
  /// [Cog] is defined by its [def] function. Using the [AutomaticCogController]
  /// passed into it, the [def] function can link other Cogs and/or external
  /// state to derive the value of the surrounding automatic [Cog].
  /// ```dart
  /// final myAutoCog = Cog.auto((c) {
  ///   final cogDepValue = c.link(cogDep);
  ///   final nonCogDepValue = c.linkNonCog(nonCogDep, ...);
  ///
  ///   return cogDepValue.combineWith(nonCogDepValue);
  /// });
  /// ```
  /// * [def] defines the resulting automatic [Cog] by linking other Cogs and/or
  ///   external state and returning the automatic [Cog]'s value
  /// * [async] specifies the resulting automatic [Cog]'s concurrency strategy
  ///   when [def] returns a [Future] - defaults to [Async.parallel]
  /// * [debugLabel] is the optional description of the state wrapped by the
  ///   resulting automatic [Cog]
  /// * [eq] is the [Function] used to determine if two different values of the
  ///   resulting automatic [Cog] should be treated as equivalent - defaults to
  ///   the `==` operator
  /// * [init] returns the initial value of the resulting automatic [Cog] - this
  ///   [Function] is only necessary if [def] returns a [Future]
  /// * [registry] is the [CogRegistry] with which the resulting automatic [Cog]
  ///   should be registered upon instantiation
  /// * [spin] optionally specifies the [SpinType] of the resulting automatic
  ///   [Cog] - for more information on what [Spin] is and how it works, see the
  ///   [Cog] docs
  /// * [ttl] optionally specifies how long it should take for values of the
  ///   resulting automatic [Cog] to become stale - defaults to ∞
  /// {@endtemplate}
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

  /// Creates a new manual [Cog].
  ///
  /// Manual Cogs are assigned values imperatively with the `write(...)` method.
  ///
  /// * [init] returns the initial value of the resulting manual [Cog]
  /// * [debugLabel] is the optional description of the state wrapped by the
  ///   resulting manual [Cog]
  /// * [eq] is the [Function] used to determine if two different values of the
  ///   resulting manual [Cog] should be treated as equivalent - defaults to the
  ///   `==` operator
  /// * [registry] is the [CogRegistry] with which the resulting manual [Cog]
  ///   should be registered upon instantiation
  /// * [spin] optionally specifies the [SpinType] of the resulting manual [Cog]
  ///   - for more information on what [Spin] is and how it works, see the [Cog]
  ///   docs
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

  /// Internal [Cog] super constructor.
  Cog._({
    required this.debugLabel,
    required this.eq,
    required CogRegistry? registry,
    required this.spin,
  }) {
    ordinal = (registry ?? GlobalCogRegistry.instance).register(this);
  }

  /// Returns the current value of the specified [spin] of this [Cog] within the
  /// given [cogtext].
  ///
  /// {@macro cog_like.spin}
  ValueType read(Cogtext cogtext, {SpinType? spin}) {
    assert(thatSpinsMatch(this, spin));

    final cogState = cogtext.runtime.acquire(cog: this, cogSpin: spin);

    return cogState.evaluate();
  }

  /// Returns a [Stream] that emits value of the specified [spin] of this [Cog]
  /// iven [cogtext] as it changes.
  ///
  /// Importantly, the resulting [Stream] does not emit upon subscription - only
  /// on change.
  ///
  /// [priority] specifies how urgently, relative to other listeners, the
  /// resulting [Stream] should receive new emissions - defaults to
  /// [Priority.normal]
  ///
  /// {@macro cog_like.spin}
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
