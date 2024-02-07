import 'dart:async';

import 'cog.dart';
import 'cog_state_runtime.dart';
import 'common.dart';
import 'notification_urgency.dart';
import 'staleness.dart';

part 'automatic_cog_state.dart';
part 'cog_state_listening_post.dart';
part 'manual_cog_state.dart';

sealed class CogState<ValueType, SpinType,
    CogType extends Cog<ValueType, SpinType>> {
  final CogType cog;

  final CogStateOrdinal ordinal;

  final CogStateRuntime runtime;

  CogStateRevision _revision = initialCogStateRevision;

  final SpinType? _spin;

  var _staleness = Staleness.stale;

  ValueType _value;

  CogState({
    required this.cog,
    required this.ordinal,
    required SpinType? spin,
    required this.runtime,
  })  : _spin = spin,
        _value = cog.init();

  bool get isActuallyStale => false;

  void maybeRevise(ValueType value) {
    final shouldRevise = !cog.eq(_value, value);

    if (shouldRevise) {
      runtime.logging.debug(
        this,
        'new revision - marking followers as stale and setting value to',
        value,
      );

      _revision++;
      _value = value;

      for (final followerOrdinal in runtime.followerOrdinalsOf(ordinal)) {
        runtime[followerOrdinal].staleness = Staleness.stale;
      }

      runtime.maybeNotifyListenersOf(ordinal);
    } else {
      runtime.logging
          .debug(this, 'no revision - new value was equal to old value');
    }

    _updateStaleness(Staleness.fresh);
  }

  CogStateRevision get revision => _revision;

  SpinType get spin {
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

  SpinType? get spinOrNull => _spin;

  Staleness get staleness {
    if (_staleness == Staleness.maybeStale) {
      final actualStaleness =
          isActuallyStale ? Staleness.stale : Staleness.fresh;

      runtime.logging.debug(
        this,
        'updating staleness form maybeStale to',
        actualStaleness,
      );
      runtime.telemetry.recordCogStateStalenessChange(ordinal);

      _staleness = actualStaleness;
    }

    return _staleness;
  }

  set staleness(Staleness staleness) {
    assert(() {
      if (staleness == Staleness.fresh) {
        throw ArgumentError('Staleness cannot be set to fresh externally');
      }

      return true;
    }());

    final didUpdateStaleness = _updateStaleness(staleness);

    if (didUpdateStaleness && staleness != Staleness.fresh) {
      runtime.maybeNotifyListenersOf(ordinal);

      for (final followerOrdinal in runtime.followerOrdinalsOf(ordinal)) {
        runtime[followerOrdinal].staleness = Staleness.maybeStale;
      }
    }
  }

  ValueType get value => _value;

  bool _updateStaleness(Staleness staleness) {
    if (staleness == _staleness) {
      return false;
    }

    runtime.logging.debug(this, 'staleness is becoming', staleness);
    runtime.telemetry.recordCogStateStalenessChange(ordinal);

    _staleness = staleness;

    return true;
  }
}