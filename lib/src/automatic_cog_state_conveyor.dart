part of 'cog_state.dart';

sealed class AutomaticCogStateConveyor<ValueType, SpinType> {
  final AutomaticCogState<ValueType, SpinType> _cogState;

  final _NextValueCallback<ValueType> _onNextValue;

  AutomaticCogStateConveyor({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required _NextValueCallback<ValueType> onNextValue,
  })  : _cogState = cogState,
        _onNextValue = onNextValue;

  void convey({bool quietly = false});
}

final class SyncAutomaticCogStateConveyor<ValueType, SpinType>
    extends AutomaticCogStateConveyor<ValueType, SpinType>
    implements AutomaticCogController<ValueType, SpinType> {
  var _linkedLeaderOrdinals = <CogStateOrdinal>[];

  var _previouslyLinkedLeaderOrdinals = <CogStateOrdinal>[];

  SyncAutomaticCogStateConveyor({
    required super.cogState,
    required super.onNextValue,
  });

  @override
  CurrValueType curr<CurrValueType extends ValueType>(CurrValueType orElse) =>
      _cogState._hasValue ? _cogState._value as CurrValueType : orElse;

  @override
  LinkedCogStateType link<LinkedCogStateType, LinkedCogSpinType>(
    Cog<LinkedCogStateType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final cogState = _cogState._runtime.acquire(cog: cog, cogSpin: spin);

    _linkedLeaderOrdinals.add(cogState.ordinal);

    return cogState.evaluate();
  }

  @override
  SpinType get spin {
    assert(() {
      if (_cogState.cog.spin == null) {
        throw StateError(
          'Cannot read cog spin - '
          'this cog definition does not specify a spin type',
        );
      }

      return true;
    }());

    return _cogState._spin as SpinType;
  }

  @override
  void convey({bool quietly = false}) {
    // Swap the cog value leader tracking lists so that we can use them
    // for a new def invocation.
    _swapLeaderOrdinals();

    _cogState._runtime.logging.debug(_cogState, 'invoking cog definition');
    _cogState._runtime.telemetry.recordCogStateRecalculation(_cogState.ordinal);

    final defResult = _cogState.cog.def(this);

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
        _cogState._runtime.terminateCogStateDependency(
          followerCogStateOrdinal: _cogState.ordinal,
          leaderCogStateOrdinal: _previouslyLinkedLeaderOrdinals[i],
        );

        i++;
      } else if (_previouslyLinkedLeaderOrdinals[i] >
          _linkedLeaderOrdinals[j]) {
        // Looks like we have a newly linked leader ordinal.
        _cogState._runtime.renewCogStateDependency(
          followerCogStateOrdinal: _cogState.ordinal,
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
      _cogState._runtime.terminateCogStateDependency(
        followerCogStateOrdinal: _cogState.ordinal,
        leaderCogStateOrdinal: _previouslyLinkedLeaderOrdinals[i],
      );

      i++;
    }
    while (j < _linkedLeaderOrdinals.length) {
      _cogState._runtime.renewCogStateDependency(
        followerCogStateOrdinal: _cogState.ordinal,
        leaderCogStateOrdinal: _linkedLeaderOrdinals[j],
      );

      j++;
    }

    _onNextValue(defResult, !quietly);
  }

  void _swapLeaderOrdinals() {
    final previouslyLinkedLeaderOrdinals = _previouslyLinkedLeaderOrdinals;

    _previouslyLinkedLeaderOrdinals = _linkedLeaderOrdinals;

    _linkedLeaderOrdinals = previouslyLinkedLeaderOrdinals..clear();
  }
}

typedef _NextValueCallback<ValueType> = void Function(
  ValueType nextValue,
  bool shouldNotify,
);
