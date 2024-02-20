import 'dart:async';

import 'async.dart';
import 'cog.dart';
import 'cog_state_runtime.dart';
import 'common.dart';
import 'priority.dart';
import 'staleness.dart';

part 'async_automatic_cog_state_conveyor.dart';
part 'automatic_cog_invocation_frame.dart';
part 'automatic_cog_state.dart';
part 'automatic_cog_state_conveyor.dart';
part 'cog_state_listening_post.dart';
part 'manual_cog_state.dart';
part 'sync_automatic_cog_state_conveyor.dart';

sealed class CogState<ValueType, SpinType,
    CogType extends Cog<ValueType, SpinType>> {
  final CogType cog;

  final CogStateOrdinal ordinal;

  CogStateRevision _revision = initialCogStateRevision - 1;

  final CogStateRuntime _runtime;

  final SpinType? _spin;

  var _staleness = Staleness.stale;

  late ValueType _value;

  CogState({
    required this.cog,
    required this.ordinal,
    required SpinType? spin,
    required CogStateRuntime runtime,
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

  void init() {}

  bool get isActuallyStale => false;

  void markStale({
    Staleness staleness = Staleness.stale,
  }) {
    assert(() {
      if (staleness == Staleness.fresh) {
        throw ArgumentError('Staleness cannot be set to fresh externally');
      }

      return true;
    }());

    final didUpdateStaleness = _updateStaleness(staleness);

    if (didUpdateStaleness && staleness != Staleness.fresh) {
      _runtime.maybeNotifyListenersOf(ordinal);

      for (final followerOrdinal in _runtime.followerOrdinalsOf(ordinal)) {
        _runtime[followerOrdinal].markStale(staleness: Staleness.maybeStale);
      }
    }
  }

  void maybeRevise(ValueType value, {bool shouldNotify = true}) {
    final shouldRevise = !_hasValue || !cog.eq(_value, value);

    if (shouldRevise) {
      _runtime.logging.debug(
        this,
        'new revision - marking followers as stale and setting value to',
        value,
      );

      _revision++;
      _value = value;

      for (final followerOrdinal in _runtime.followerOrdinalsOf(ordinal)) {
        _runtime[followerOrdinal].markStale();
      }

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
    }

    _updateStaleness(Staleness.fresh);
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

  Staleness get staleness {
    if (_staleness == Staleness.maybeStale) {
      final actualStaleness =
          isActuallyStale ? Staleness.stale : Staleness.fresh;

      _runtime.logging.debug(
        this,
        'updating staleness form maybeStale to',
        actualStaleness,
      );
      _runtime.telemetry.recordCogStateStalenessChange(ordinal);

      _staleness = actualStaleness;
    }

    return _staleness;
  }

  bool get _hasValue => _revision >= initialCogStateRevision;

  bool _updateStaleness(Staleness staleness) {
    if (staleness == _staleness) {
      return false;
    }

    _runtime.logging.debug(this, 'staleness is becoming', staleness);
    _runtime.telemetry.recordCogStateStalenessChange(ordinal);

    _staleness = staleness;

    return true;
  }
}
