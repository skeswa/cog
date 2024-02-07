part of 'cog_value.dart';

final class AutomaticCogValue<ValueType, SpinType>
    extends CogValue<ValueType, SpinType, AutomaticCog<ValueType, SpinType>>
    implements AutomaticCogController<ValueType, SpinType> {
  CogValueRevision _ancestorRevisionHash = initialCogValueRevision;

  late var _linkedAncestorOrdinals = <CogValueOrdinal>[];

  late var _previouslyLinkedAncestorOrdinals = <CogValueOrdinal>[];

  var _staleness = Staleness.stale;

  AutomaticCogValue({
    required super.cog,
    required super.ordinal,
    required super.runtime,
    required super.spin,
  });

  @override
  ValueType get curr => super.value;

  @override
  LinkedCogValueType link<LinkedCogValueType, LinkedCogSpinType>(
    Cog<LinkedCogValueType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  }) {
    assert(() {
      if (cog.spin == null && spin != null) {
        throw ArgumentError(
          'When linking to a cog that does not specify a spin type, '
          'a spin value cannot be specified',
        );
      }

      return true;
    }());

    final cogValue = runtime.acquire(cog: cog, cogSpin: spin);

    _linkedAncestorOrdinals.add(cogValue.ordinal);

    return cogValue.value;
  }

  @override
  void markAsMaybeStale() {
    if (_staleness != Staleness.fresh) {
      runtime.logging
          .debug(this, 'not marking as maybeStale - already maybeStale');

      return;
    }

    runtime.logging.debug(this, 'marking as maybe stale');
    runtime.telemetry.recordCogValueStalenessChange(ordinal);

    _staleness = Staleness.maybeStale;

    for (final descendantOrdinal in runtime.descendantOrdinalsOf(ordinal)) {
      runtime[descendantOrdinal].markAsMaybeStale();
    }
  }

  @override
  void markAsStale() {
    if (_staleness == Staleness.stale) {
      runtime.logging.debug(this, 'not marking as stale - already stale');

      return;
    }

    runtime.logging.debug(this, 'marking as stale');
    runtime.telemetry.recordCogValueStalenessChange(ordinal);

    _staleness = Staleness.stale;

    for (final descendantOrdinal in runtime.descendantOrdinalsOf(ordinal)) {
      runtime[descendantOrdinal].markAsMaybeStale();
    }
  }

  @override
  CogValueRevision get revision {
    _maybeRecalculateValue();

    return _revision;
  }

  @override
  ValueType get value {
    _maybeRecalculateValue();

    return _value;
  }

  CogValueRevisionHash _calculateAncestorRevisionHash() {
    var hash = ancestorRevisionHashSeed;

    for (final ancestorOrdinal in runtime.ancestorOrdinalsOf(ordinal)) {
      hash += ancestorRevisionHashScalingFactor * hash +
          runtime[ancestorOrdinal].revision;
    }

    return hash;
  }

  void _maybeRecalculateValue() {
    _maybeRecalculateStaleness();

    if (_staleness == Staleness.stale) {
      _recalculateValue();
    } else {
      runtime.logging.debug(
        this,
        'skipping value re-calculation due to lack of staleness',
      );
    }
  }

  void _recalculateValue() {
    // Swap the cog value ancestor tracking lists so that we can use them
    // for a new def invocation.
    _swapAncestorOrdinals();

    runtime.logging.debug(this, 'invoking cog definition');
    runtime.telemetry.recordCogValueRecalculation(ordinal);

    final defResult = cog.def(this);

    // TODO(skeswa): asyncify all of the logic below
    if (defResult is Future) {
      throw UnsupportedError('No async yet buckaroo');
    }

    // Ensure that the linked ordinals are in order so we can compare to
    // previously linked ancestor ordinals.
    _linkedAncestorOrdinals.sort();

    // Look for differences in the two sorted lists of ancestor ordinals.
    int i = 0, j = 0;
    while (i < _previouslyLinkedAncestorOrdinals.length &&
        j < _linkedAncestorOrdinals.length) {
      if (_previouslyLinkedAncestorOrdinals[i] < _linkedAncestorOrdinals[j]) {
        // Looks like this previously linked ancestor ordinal is no longer linked.
        runtime.terminateCogValueAncestry(
          ancestorCogValueOrdinal: _previouslyLinkedAncestorOrdinals[i],
          descendantCogValueOrdinal: ordinal,
        );

        i++;
      } else if (_previouslyLinkedAncestorOrdinals[i] >
          _linkedAncestorOrdinals[j]) {
        // Looks like we have a newly linked ancestor ordinal.
        runtime.renewCogValueAncestry(
          ancestorCogValueOrdinal: _linkedAncestorOrdinals[j],
          descendantCogValueOrdinal: ordinal,
        );

        j++;
      } else {
        // This ancestor ordinal has stayed linked.

        i++;
        j++;
      }
    }

    // We need to account for one of the lists being longer than the other.
    while (i < _previouslyLinkedAncestorOrdinals.length) {
      runtime.terminateCogValueAncestry(
        ancestorCogValueOrdinal: _previouslyLinkedAncestorOrdinals[i],
        descendantCogValueOrdinal: ordinal,
      );

      i++;
    }
    while (j < _linkedAncestorOrdinals.length) {
      runtime.renewCogValueAncestry(
        ancestorCogValueOrdinal: _linkedAncestorOrdinals[j],
        descendantCogValueOrdinal: ordinal,
      );

      j++;
    }

    runtime.logging.debug(
      this,
      'updating ancestor revision hash and resetting staleness to fresh',
    );
    runtime.telemetry.recordCogValueStalenessChange(ordinal);

    _ancestorRevisionHash = _calculateAncestorRevisionHash();
    _staleness = Staleness.fresh;

    return maybeRevise(defResult);
  }

  void _maybeRecalculateStaleness() {
    if (_staleness != Staleness.maybeStale) {
      runtime.logging
          .debug(this, 'not recalculating staleness - not maybeStale');

      return;
    }

    final latestAncestorRevisionHash = _calculateAncestorRevisionHash();

    if (_ancestorRevisionHash != latestAncestorRevisionHash) {
      runtime.logging.debug(
        this,
        'ancestor revision hash changed - updating staleness to stale',
      );
      runtime.telemetry.recordCogValueStalenessChange(ordinal);

      _staleness = Staleness.stale;
    } else {
      runtime.logging.debug(
        this,
        'ancestor revision hash did not change - updating staleness to fresh',
      );
      runtime.telemetry.recordCogValueStalenessChange(ordinal);

      _staleness = Staleness.fresh;
    }
  }

  void _swapAncestorOrdinals() {
    final previouslyLinkedAncestorOrdinals = _previouslyLinkedAncestorOrdinals;

    _previouslyLinkedAncestorOrdinals = _linkedAncestorOrdinals;

    _linkedAncestorOrdinals = previouslyLinkedAncestorOrdinals..clear();
  }
}
