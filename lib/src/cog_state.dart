import 'dart:async';

import 'async.dart';
import 'cog.dart';
import 'cog_runtime.dart';
import 'common.dart';
import 'priority.dart';
import 'spin.dart';
import 'staleness.dart';

part 'async_automatic_cog_state_conveyor.dart';
part 'automatic_cog_invocation_frame.dart';
part 'automatic_cog_state.dart';
part 'automatic_cog_state_conveyor.dart';
part 'cog_state_listening_post.dart';
part 'manual_cog_state.dart';
part 'non_cog_tracker.dart';
part 'sync_automatic_cog_state_conveyor.dart';

/// Internal controller that manages the state and lifecycle for a specific
/// [Spin] of a particular [cog].
///
/// Importantly, [CogState] is an implementation detail that should not be
/// directly interacted with by the library user.
///
/// {@template cog_state.spin}
/// If a Cog specifies a [Spin], each corresponding [CogState] specifies a
/// [_spin] value of type [SpinType]; in this configuration, Cog and [CogState]
/// are one-to-many. Otherwise, if a Cog does not specify a [Spin], it was
/// precisely one [CogState] having a `null` [_spin].
/// {@endtemplate}
///
/// Each [CogState] is bound to precisely one [CogRuntime].
sealed class CogState<ValueType, SpinType,
    CogType extends CogLike<ValueType, SpinType>> {
  /// Cog instance for which this [CogState] controls state changes and
  /// lifecycle.
  final CogType cog;

  /// Integer that uniquely identifies this [CogState] relative to all other
  /// instances of [CogState] registered with the [CogRuntime] to which this
  /// [CogState] belongs.
  final CogStateOrdinal ordinal;

  /// Ever-increasing integer that changes value every time this [CogState]'s
  /// value changes.
  CogStateRevision _revision = initialCogStateRevision - 1;

  /// [CogRuntime] to which this [CogState] belongs.
  final CogRuntime _runtime;

  /// Cog [Spin] value to which this [CogState] is bound.
  ///
  /// {@macro cog_state.spin}
  final SpinType? _spin;

  /// Describes whether [_value] needs to be recalculated.
  var _staleness = Staleness.stale;

  /// Most-recently calculated value of this [CogState].
  ///
  /// This field is `late` because, before this [CogState] is initialized via
  /// [init], it does not yet have a value.
  late ValueType _value;

  /// Creates a new [CogState].
  ///
  /// * [runtime] is the [CogRuntime] to which the resulting [CogState] should
  ///   belong
  /// * [spin] is the Cog [Spin] value to which the resulting [CogState] should
  ///   be bound
  CogState({
    required this.cog,
    required this.ordinal,
    required CogRuntime runtime,
    required SpinType? spin,
  })  : _runtime = runtime,
        _spin = spin;

  /// Returns the current value of this [CogState], throwing when said value has
  /// not yet been calculated.
  ///
  /// In some implementations of [CogState], invocations of this method may
  /// cause value to be recalculated before being returned.
  ValueType evaluate() {
    _assertHasValue();

    return _value;
  }

  /// Method invoked on this [CogState] almost immediately following that of the
  /// constructor.
  ///
  /// NOTE: [init] is called separately from the constructor to allow for cyclic
  /// dependencies between instances of [CogState].
  void init();

  /// Specifies the desired [staleness] of [CogState] followers of this
  /// [CogState], potentially notifying affected listeners to re-evaluate the
  /// respective [CogState] instances.
  ///
  /// If left unspecified, [staleness] defaults to [Staleness.stale].
  void markFollowersStale([Staleness? staleness]) {
    final followerOrdinals = _runtime.followerOrdinalsOf(ordinal);

    final followerOrdinalCount = followerOrdinals.length;

    for (var i = 0; i < followerOrdinalCount; i++) {
      final followerOrdinal = followerOrdinals[i];

      _runtime[followerOrdinal]?.markStale(staleness);
    }
  }

  /// Specifies the desired [staleness] of this [CogState], potentially
  /// notifying listeners to re-evaluate this [CogState].
  ///
  /// If left unspecified, [staleness] defaults to [Staleness.stale].
  void markStale([Staleness? staleness]) {
    staleness ??= Staleness.stale;

    assert(() {
      if (staleness == Staleness.fresh) {
        throw ArgumentError('Staleness cannot be set to fresh externally');
      }

      return true;
    }());

    final didUpdateStaleness = _maybeUpdateStaleness(staleness);

    if (!didUpdateStaleness) {
      _runtime.logging.debug(
        this,
        'marked stale but staleness did not change',
      );

      return;
    }

    _runtime.maybeNotifyListenersOf(ordinal);
    markFollowersStale(Staleness.maybeStale);
  }

  /// Changes the value of this [CogState] to [value] if it is qualitatively
  /// different, returning `true` if a change was made.
  ///
  /// [shouldNotify] should be `false` when value changes should be made without
  /// notifying listeners.
  bool maybeRevise(ValueType value, {required bool shouldNotify}) {
    final shouldRevise = !_hasValue || !_eq(_value, value);

    if (shouldRevise) {
      _runtime.logging.debug(
        this,
        'new revision - marking followers as stale and setting value to',
        value,
      );

      _revision++;
      _value = value;

      _maybeUpdateStaleness(Staleness.fresh);

      markFollowersStale();

      if (shouldNotify) {
        _runtime.maybeNotifyListenersOf(ordinal);
      } else {
        _runtime.logging.debug(
          this,
          'skipping listener notification - shouldNotify = false',
        );
      }
    } else {
      _runtime.logging
          .debug(this, 'no revision - new value was equal to old value');

      _maybeUpdateStaleness(Staleness.fresh);
    }

    return shouldRevise;
  }

  /// Ever-increasing integer that changes value every time this [CogState]'s
  /// value changes.
  CogStateRevision get revision => _revision;

  /// Spin of this [CogState], or `null` if the Cog underlying this [CogState]
  /// does not have an associated [Spin].
  ///
  /// Importantly, `null` could mean that this [CogState] simply has a spin of
  /// `null`.
  SpinType? get spinOrNull => _spin;

  /// Evaluates to the spin of this [CogState], throwing if the Cog underlying
  /// this [CogState] does not have an associated [Spin].
  SpinType get spinOrThrow {
    assert(() {
      if (cog.spin == null) {
        throw StateError(
          'Cannot read cog spin - '
          'this cog definition does not specify a spin type',
        );
      }

      return true;
    }());

    return _spin as SpinType;
  }

  /// Throws if this [CogState] does not yet have a value.
  void _assertHasValue() {
    if (!_hasValue) {
      throw StateError(
        'Cog state has not yet been initialized. Typically, this happens '
        'if the initial invocation of the Cog definition threw.',
      );
    }
  }

  /// Returns `true` if [cog] considers values [a] and [b] to be qualitatively
  /// equivalent.
  bool _eq(ValueType a, ValueType b) => cog.eq?.call(a, b) ?? a == b;

  /// `true` if this [CogState] currently has a value.
  bool get _hasValue => _revision >= initialCogStateRevision;

  /// Changes [_staleness] to [staleness] if necessary, return `true` if
  /// [_staleness] actually changed.
  bool _maybeUpdateStaleness(Staleness staleness) {
    if (staleness == _staleness) {
      return false;
    }

    _runtime.logging.debug(this, 'staleness is becoming', staleness);
    _runtime.telemetry.recordCogStateStalenessChange(ordinal);

    _staleness = staleness;

    return true;
  }
}
