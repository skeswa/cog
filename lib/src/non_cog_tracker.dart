part of 'cog_state.dart';

final class NonCogTracker {
  final AutomaticCogState _cogState;
  final _trackedNonCogByNonCog = <_NonCog, _TrackedNonCog>{};

  NonCogTracker({
    required AutomaticCogState cogState,
  }) : _cogState = cogState;

  TrackedNonCogRevisionHash get revisionHash {
    var hash = revisionHashSeed;

    final currentInvocationFrameOrdinal =
        _cogState._currentInvocationFrameOrdinal;

    for (final trackedNonCog in _trackedNonCogByNonCog.values) {
      if (trackedNonCog.isTracking &&
          trackedNonCog._trackingInvocationFrameOrdinals
              .contains(currentInvocationFrameOrdinal)) {
        hash += revisionHashScalingFactor * hash + trackedNonCog._revision;
      }
    }

    return hash;
  }

  ValueType track<NonCogType extends Object, SubscriptionType, ValueType>({
    required LinkNonCogInit<NonCogType, ValueType> init,
    required AutomaticCogInvocationFrameOrdinal invocationFrameOrdinal,
    required NonCogType nonCog,
    required LinkNonCogSubscribe<NonCogType, SubscriptionType, ValueType>
        subscribe,
    required LinkNonCogUnsubscribe<NonCogType, SubscriptionType, ValueType>
        unsubscribe,
  }) {
    var trackedNonCog = _trackedNonCogByNonCog[nonCog] ??=
        _TrackedNonCog<NonCogType, SubscriptionType, ValueType>(
      initialInvocationFrameOrdinal: invocationFrameOrdinal,
      init: init,
      nonCog: nonCog,
      nonCogTracker: this,
      subscribe: subscribe,
      unsubscribe: unsubscribe,
    );

    return trackedNonCog.up(invocationFrameOrdinal);
  }

  void untrackAll({
    required AutomaticCogInvocationFrameOrdinal? invocationFrameOrdinal,
  }) {
    if (invocationFrameOrdinal == null) {
      return;
    }

    for (final trackedNonCog in _trackedNonCogByNonCog.values) {
      trackedNonCog.down(invocationFrameOrdinal);
    }

    _cogState._runtime.scheduler.scheduleBackgroundTask(_cullUntrackedNonCogs);
  }

  void _cullUntrackedNonCogs() {
    _cogState._runtime.logging.debug(
      _cogState,
      'culling subscriptions to untracked non-cogs',
    );

    _trackedNonCogByNonCog
        .removeWhere((_, trackedNonCog) => !trackedNonCog.isTracking);
  }
}

typedef _NonCog = Object;

final class _TrackedNonCog<NonCogType, SubscriptionType, ValueType> {
  final NonCogType _nonCog;
  final NonCogTracker _nonCogTracker;
  final LinkNonCogSubscribe<NonCogType, SubscriptionType, ValueType> _subscribe;
  SubscriptionType? _subscription;
  final _trackingInvocationFrameOrdinals =
      <AutomaticCogInvocationFrameOrdinal>[];
  final LinkNonCogUnsubscribe<NonCogType, SubscriptionType, ValueType>
      _unsubscribe;
  var _revision = initialTrackedNonCogRevision;
  ValueType _value;

  _TrackedNonCog({
    required AutomaticCogInvocationFrameOrdinal initialInvocationFrameOrdinal,
    required LinkNonCogInit<NonCogType, ValueType> init,
    required NonCogType nonCog,
    required NonCogTracker nonCogTracker,
    required LinkNonCogSubscribe<NonCogType, SubscriptionType, ValueType>
        subscribe,
    required LinkNonCogUnsubscribe<NonCogType, SubscriptionType, ValueType>
        unsubscribe,
  })  : _nonCog = nonCog,
        _nonCogTracker = nonCogTracker,
        _subscribe = subscribe,
        _unsubscribe = unsubscribe,
        _value = init(nonCog);

  void down(AutomaticCogInvocationFrameOrdinal ordinal) {
    _trackingInvocationFrameOrdinals.remove(ordinal);

    if (_trackingInvocationFrameOrdinals.isNotEmpty) {
      return;
    }

    final subscription = _subscription;

    if (subscription == null) {
      return;
    }

    _nonCogTracker._cogState._runtime.logging.debug(
      _nonCogTracker._cogState,
      'untracking non-cog',
      _nonCog,
    );
    _nonCogTracker._cogState._runtime.telemetry
        .recordCogStateNonCogDependencyTermination(
      followerCogStateOrdinal: _nonCogTracker._cogState.ordinal,
    );

    _unsubscribe(_nonCog, _onNextValue, subscription);

    _subscription = null;
  }

  bool get isTracking => _subscription != null;

  ValueType up(AutomaticCogInvocationFrameOrdinal ordinal) {
    if (!_trackingInvocationFrameOrdinals.contains(ordinal)) {
      _trackingInvocationFrameOrdinals.add(ordinal);

      if (_trackingInvocationFrameOrdinals.length == 1) {
        _subscription = _subscribe(_nonCog, _onNextValue);

        _nonCogTracker._cogState._runtime.logging.debug(
          _nonCogTracker._cogState,
          'tracking non-cog',
          _nonCog,
        );
        _nonCogTracker._cogState._runtime.telemetry
            .recordCogStateNonCogDependencyRenewal(
          followerCogStateOrdinal: _nonCogTracker._cogState.ordinal,
        );
      }
    }

    return _value;
  }

  void _onNextValue(ValueType value) {
    _value = value;
    _revision++;

    final currentInvocationFrameOrdinal =
        _nonCogTracker._cogState._currentInvocationFrameOrdinal;

    if (!_trackingInvocationFrameOrdinals
        .contains(currentInvocationFrameOrdinal)) {
      _nonCogTracker._cogState._runtime.logging.debug(
        _nonCogTracker._cogState,
        'ignoring non-current value emission from non-cog',
        _nonCog,
      );

      return;
    }

    _nonCogTracker._cogState._onNonCogDependencyChange();
  }
}
