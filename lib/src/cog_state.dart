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
/// directly interacted with by the library user. If a Cog specifies a [Spin],
/// each corresponding [CogState] specifies a [_spin] value of type [SpinType];
/// in this configuration, Cog and [CogState] are one-to-many. Otherwise, if a
/// Cog does not specify a [Spin], it was precisely one [CogState] having a
/// `null` [_spin].
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
  ///
  /// Despite being specified as a getter, [ordinal] is expected to never change
  /// and **must** only identify this Cog.
  final CogStateOrdinal ordinal;

  CogStateRevision _revision = initialCogStateRevision - 1;

  final CogRuntime _runtime;

  final SpinType? _spin;

  var _staleness = Staleness.stale;

  late ValueType _value;

  CogState({
    required this.cog,
    required this.ordinal,
    required SpinType? spin,
    required CogRuntime runtime,
  })  : _runtime = runtime,
        _spin = spin;

  bool assertHasValue() {
    if (!_hasValue) {
      throw StateError(
        'Cog state has not yet been initialized. Typically, this happens '
        'if the initial invocation of the Cog definition threw.',
      );
    }

    return true;
  }

  ValueType evaluate() {
    assertHasValue();

    return _value;
  }

  void init();

  void markFollowersStale({
    Staleness staleness = Staleness.stale,
  }) {
    final followerOrdinals = _runtime.followerOrdinalsOf(ordinal);

    final followerOrdinalCount = followerOrdinals.length;

    for (var i = 0; i < followerOrdinalCount; i++) {
      final followerOrdinal = followerOrdinals[i];

      _runtime[followerOrdinal]?.markStale(staleness: staleness);
    }
  }

  void markStale({
    Staleness staleness = Staleness.stale,
  }) {
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
    markFollowersStale(staleness: Staleness.maybeStale);
  }

  bool maybeRevise(
    ValueType value, {
    required bool shouldNotify,
  }) {
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

  CogStateRevision get revision => _revision;

  SpinType? get spinOrNull => _spin;

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

  bool _eq(ValueType a, ValueType b) => cog.eq?.call(a, b) ?? a == b;

  bool get _hasValue => _revision >= initialCogStateRevision;

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
