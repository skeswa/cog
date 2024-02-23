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
      onNextValue: _onNextValue,
    );

    _conveyor.init();
  }

  @override
  bool get isActuallyStale {
    final latestLeaderRevisionHash = _calculateLeaderRevisionHash();

    return latestLeaderRevisionHash != _leaderRevisionHash;
  }

  @override
  void markFollowersStale({Staleness staleness = Staleness.stale}) {
    if (!_conveyor.propagatesPotentialStaleness &&
        staleness == Staleness.maybeStale) {
      _runtime.logging.debug(
        this,
        'not marking followers as maybe stale - '
        'this cog does not propagate potential staleness',
      );

      return;
    }

    super.markFollowersStale(staleness: staleness);
  }

  @override
  void markStale({
    Staleness staleness = Staleness.stale,
  }) {
    super.markStale(staleness: staleness);

    if (_conveyor.isEager) {
      _runtime.logging.debug(
        this,
        'this cog state conveys eagerly - '
        'might need to re-convey based on change in staleness',
      );

      _maybeReconvey();
    }
  }

  @override
  bool maybeRevise(ValueType value, {required bool shouldNotify}) {
    final didRevise = super.maybeRevise(value, shouldNotify: shouldNotify);

    if (didRevise) {
      _maybeScheduleTtl();
    }

    return didRevise;
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

  void _maybeReconvey({bool shouldForce = false}) {
    if (!shouldForce) {
      final recalculatedStaleness = recalculateStaleness();

      if (recalculatedStaleness != Staleness.stale) {
        _runtime.logging.debug(
          this,
          'skipping convey due to lack of staleness',
        );

        return;
      }
    }

    _runtime.logging.debug(this, 're-conveying');

    _conveyor.convey(shouldForce: shouldForce);
  }

  void _maybeScheduleTtl() {
    final ttl = cog.ttl;

    if (ttl == null) {
      return;
    }

    _runtime.logging.debug(this, '(re-)scheduling TTL');

    _runtime.scheduler.scheduleDelayedTask(_onTtlExpiration, ttl);
  }

  void _onNextValue({
    required ValueType nextValue,
    required bool shouldNotify,
  }) {
    _runtime.logging.debug(
      this,
      'next value has conveyed - updating leader revision hash',
    );

    _leaderRevisionHash = _calculateLeaderRevisionHash();

    maybeRevise(nextValue, shouldNotify: shouldNotify);
  }

  void _onTtlExpiration() {
    _runtime.logging.debug(this, 'TTL expired - re-calculating value...');

    _maybeReconvey(shouldForce: true);
    _maybeScheduleTtl();
  }
}
