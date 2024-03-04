part of 'cog_state.dart';

final class AutomaticCogState<ValueType, SpinType>
    extends CogState<ValueType, SpinType, AutomaticCog<ValueType, SpinType>> {
  late final AutomaticCogStateConveyor<ValueType, SpinType> _conveyor;
  AutomaticCogInvocationFrameOrdinal _currentInvocationFrameOrdinal =
      _initialInvocationFrameOrdinal - 1;
  CogStateRevision? _leaderRevisionHash;
  NonCogTracker? _nonCogTracker;

  AutomaticCogState({
    required super.cog,
    required super.ordinal,
    required super.runtime,
    required super.spin,
  });

  @override
  ValueType evaluate() {
    _maybeConvey();

    return _value;
  }

  @override
  void init() {
    _conveyor = AutomaticCogStateConveyor(cogState: this);

    _conveyor.init();
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
        'might need to convey based on change in staleness',
      );

      _maybeConvey();
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

  NonCogTracker get nonCogTracker =>
      _nonCogTracker ??= NonCogTracker(cogState: this);

  @override
  CogStateRevision get revision {
    _maybeConvey();

    return _revision;
  }

  CogStateRevisionHash _calculateLeaderRevisionHash() {
    var hash = revisionHashSeed;

    final nonCogTracker = _nonCogTracker;

    if (nonCogTracker != null) {
      hash += revisionHashScalingFactor * hash + nonCogTracker.revisionHash;
    }

    final leaderOrdinals = _runtime.leaderOrdinalsOf(ordinal);

    final leaderOrdinalCount = leaderOrdinals.length;

    for (var i = 0; i < leaderOrdinalCount; i++) {
      final leaderOrdinal = leaderOrdinals[i];

      hash +=
          revisionHashScalingFactor * hash + _runtime[leaderOrdinal].revision;
    }

    return hash;
  }

  bool get _isActuallyStale {
    final latestLeaderRevisionHash = _calculateLeaderRevisionHash();

    return latestLeaderRevisionHash != _leaderRevisionHash;
  }

  void _maybeConvey({bool shouldForce = false}) {
    if (!shouldForce) {
      final recalculatedStaleness = _recalculateStaleness();

      if (recalculatedStaleness != Staleness.stale) {
        _runtime.logging.debug(
          this,
          'skipping convey due to lack of staleness',
        );

        return;
      }
    }

    _runtime.logging.debug(this, 'not skipping convey');

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
    required AutomaticCogInvocationFrameOrdinal nextInvocationFrameOrdinal,
    required ValueType nextValue,
    required bool shouldNotify,
  }) {
    _runtime.logging.debug(
      this,
      'next value has conveyed - updating leader revision hash',
    );

    _currentInvocationFrameOrdinal = nextInvocationFrameOrdinal;
    _leaderRevisionHash = _calculateLeaderRevisionHash();

    maybeRevise(nextValue, shouldNotify: shouldNotify);
  }

  void _onNonCogDependencyChange() {
    _runtime.logging.debug(
      this,
      'non-cog dependency has changed - marking stale',
    );

    markStale();
  }

  void _onTtlExpiration() {
    _runtime.logging.debug(this, 'TTL expired - re-calculating value...');

    _maybeConvey(shouldForce: true);
    _maybeScheduleTtl();
  }

  Staleness _recalculateStaleness() {
    if (_staleness == Staleness.maybeStale) {
      final actualStaleness =
          _isActuallyStale ? Staleness.stale : Staleness.fresh;

      _runtime.logging.debug(
        this,
        'updating staleness from maybeStale to',
        actualStaleness,
      );
      _runtime.telemetry.recordCogStateStalenessChange(ordinal);

      _staleness = actualStaleness;
    }

    return _staleness;
  }
}
