part of 'cog_state.dart';

final class AutomaticCogState<ValueType, SpinType>
    extends CogState<ValueType, SpinType, AutomaticCog<ValueType, SpinType>>
    implements AutomaticCogController<ValueType, SpinType> {
  CogStateRevision? _leaderRevisionHash;

  late var _linkedLeaderOrdinals = <CogStateOrdinal>[];

  late var _previouslyLinkedLeaderOrdinals = <CogStateOrdinal>[];

  AutomaticCogState({
    required super.cog,
    required super.ordinal,
    required super.runtime,
    required super.spin,
  });

  @override
  ValueType curr({required ValueType orElse}) => _hasValue ? _value : orElse;

  @override
  ValueType evaluate() {
    _maybeRecalculateValue();

    return _value;
  }

  @override
  void init() {
    maybeRevise(_recalculateValue(), quietly: true);

    _maybeScheduleTtl();
  }

  @override
  bool get isActuallyStale {
    final latestLeaderRevisionHash = _calculateLeaderRevisionHash();

    return _leaderRevisionHash != latestLeaderRevisionHash;
  }

  @override
  LinkedCogStateType link<LinkedCogStateType, LinkedCogSpinType>(
    Cog<LinkedCogStateType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final cogState = runtime.acquire(cog: cog, cogSpin: spin);

    _linkedLeaderOrdinals.add(cogState.ordinal);

    return cogState.evaluate();
  }

  @override
  CogStateRevision get revision {
    _maybeRecalculateValue();

    return _revision;
  }

  CogStateRevisionHash _calculateLeaderRevisionHash() {
    var hash = leaderRevisionHashSeed;

    for (final leaderOrdinal in runtime.leaderOrdinalsOf(ordinal)) {
      hash += leaderRevisionHashScalingFactor * hash +
          runtime[leaderOrdinal].revision;
    }

    return hash;
  }

  void _maybeRecalculateValue() {
    if (staleness != Staleness.stale) {
      runtime.logging.debug(
        this,
        'skipping value re-calculation due to lack of staleness',
      );

      return;
    }

    final recalculatedValue = _recalculateValue();

    maybeRevise(recalculatedValue);
  }

  void _maybeScheduleTtl() {
    final ttl = cog.ttl;

    if (ttl == null) {
      return;
    }

    runtime.logging.debug(this, 'scheduling TTL');

    runtime.scheduler.scheduleDelayedTask(_onTtlExpiration, ttl);
  }

  void _onTtlExpiration() {
    runtime.logging.debug(this, 'TTL expired - re-calculating value...');

    _maybeRecalculateValue();
    _maybeScheduleTtl();
  }

  ValueType _recalculateValue() {
    // Swap the cog value leader tracking lists so that we can use them
    // for a new def invocation.
    _swapLeaderOrdinals();

    runtime.logging.debug(this, 'invoking cog definition');
    runtime.telemetry.recordCogStateRecalculation(ordinal);

    final defResult = cog.def(this);

    // TODO(skeswa): asyncify all of the logic below
    if (defResult is Future) {
      throw UnsupportedError('No async yet buckaroo');
    }

    // Ensure that the linked ordinals are in order so we can compare to
    // previously linked leader ordinals.
    _linkedLeaderOrdinals.sort();

    // Look for differences in the two sorted lists of leader ordinals.
    int i = 0, j = 0;
    while (i < _previouslyLinkedLeaderOrdinals.length &&
        j < _linkedLeaderOrdinals.length) {
      if (_previouslyLinkedLeaderOrdinals[i] < _linkedLeaderOrdinals[j]) {
        // Looks like this previously linked leader ordinal is no longer linked.
        runtime.terminateCogStateDependency(
          followerCogStateOrdinal: ordinal,
          leaderCogStateOrdinal: _previouslyLinkedLeaderOrdinals[i],
        );

        i++;
      } else if (_previouslyLinkedLeaderOrdinals[i] >
          _linkedLeaderOrdinals[j]) {
        // Looks like we have a newly linked leader ordinal.
        runtime.renewCogStateDependency(
          followerCogStateOrdinal: ordinal,
          leaderCogStateOrdinal: _linkedLeaderOrdinals[j],
        );

        j++;
      } else {
        // This leader ordinal has stayed linked.

        i++;
        j++;
      }
    }

    // We need to account for one of the lists being longer than the other.
    while (i < _previouslyLinkedLeaderOrdinals.length) {
      runtime.terminateCogStateDependency(
        followerCogStateOrdinal: ordinal,
        leaderCogStateOrdinal: _previouslyLinkedLeaderOrdinals[i],
      );

      i++;
    }
    while (j < _linkedLeaderOrdinals.length) {
      runtime.renewCogStateDependency(
        followerCogStateOrdinal: ordinal,
        leaderCogStateOrdinal: _linkedLeaderOrdinals[j],
      );

      j++;
    }

    runtime.logging.debug(
      this,
      'updating leader revision hash and resetting staleness to fresh',
    );
    runtime.telemetry.recordCogStateStalenessChange(ordinal);

    _leaderRevisionHash = _calculateLeaderRevisionHash();

    return defResult;
  }

  void _swapLeaderOrdinals() {
    final previouslyLinkedLeaderOrdinals = _previouslyLinkedLeaderOrdinals;

    _previouslyLinkedLeaderOrdinals = _linkedLeaderOrdinals;

    _linkedLeaderOrdinals = previouslyLinkedLeaderOrdinals..clear();
  }
}
