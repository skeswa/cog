part of 'cog_state.dart';

final class AutomaticCogState<ValueType, SpinType>
    extends CogState<ValueType, SpinType, AutomaticCog<ValueType, SpinType>> {
  late final AutomaticCogStateConveyor<ValueType, SpinType> _conveyor;
  CogStateRevision? _leaderRevisionHash;

  AutomaticCogState({
    required super.cog,
    required super.ordinal,
    required super.runtime,
    required super.spin,
  });

  @override
  ValueType evaluate() {
    _maybeReconvey();

    return _value;
  }

  @override
  void init() {
    _conveyor = AutomaticCogStateConveyor(
      cogState: this,
      onError: _onError,
      onNextValue: _onNextValue,
    );

    _maybeScheduleTtl();
  }

  @override
  bool get isActuallyStale {
    final latestLeaderRevisionHash = _calculateLeaderRevisionHash();

    return _leaderRevisionHash != latestLeaderRevisionHash;
  }

  @override
  CogStateRevision get revision {
    _maybeReconvey();

    return _revision;
  }

  CogStateRevisionHash _calculateLeaderRevisionHash() {
    var hash = leaderRevisionHashSeed;

    for (final leaderOrdinal in _runtime.leaderOrdinalsOf(ordinal)) {
      hash += leaderRevisionHashScalingFactor * hash +
          _runtime[leaderOrdinal].revision;
    }

    return hash;
  }

  void _maybeReconvey() {
    if (staleness != Staleness.stale) {
      _runtime.logging.debug(
        this,
        'skipping value re-calculation due to lack of staleness',
      );

      return;
    }

    _conveyor.convey();
  }

  void _maybeScheduleTtl() {
    final ttl = cog.ttl;

    if (ttl == null) {
      return;
    }

    _runtime.logging.debug(this, 'scheduling TTL');

    _runtime.scheduler.scheduleDelayedTask(_onTtlExpiration, ttl);
  }

  void _onError({
    required CogState<ValueType, SpinType, AutomaticCog<ValueType, SpinType>>
        cogState,
    required Object error,
    required StackTrace stackTrace,
  }) {
    _runtime.logging.error(
      cogState,
      'encountered an error while conveying',
      error,
      stackTrace,
    );
  }

  void _onNextValue({
    required ValueType nextValue,
    required bool shouldNotify,
  }) {
    _runtime.logging.debug(
      this,
      'updating leader revision hash and resetting staleness to fresh',
    );
    _runtime.telemetry.recordCogStateStalenessChange(ordinal);

    _leaderRevisionHash = _calculateLeaderRevisionHash();

    maybeRevise(nextValue, shouldNotify: shouldNotify);
  }

  void _onTtlExpiration() {
    _runtime.logging.debug(this, 'TTL expired - re-calculating value...');

    _conveyor.convey();
    _maybeScheduleTtl();
  }
}
