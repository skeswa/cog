part of 'cog_state.dart';

final class AutomaticCogInvocationFrame<ValueType, SpinType>
    implements AutomaticCogController<ValueType, SpinType> {
  final AutomaticCogInvocationFrameOrdinal ordinal;

  final AutomaticCogState<ValueType, SpinType> _cogState;
  bool _hasValue;
  final _linkedLeaderOrdinals = <CogStateOrdinal>[];
  late ValueType _value;

  AutomaticCogInvocationFrame({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required this.ordinal,
  })  : _cogState = cogState,
        _hasValue = cogState._hasValue {
    if (_hasValue) {
      _value = _cogState._value;
    } else {
      final init = _cogState.cog.init;

      if (init != null) {
        _value = init();
      }
    }
  }

  void close({required AutomaticCogInvocationFrame? currentInvocationFrame}) {
    final previouslyLinkedLeaderOrdinals =
        currentInvocationFrame?._linkedLeaderOrdinals ?? const [];

    // Ensure that the linked ordinals are in order so we can compare to
    // previously linked leader ordinals.
    //
    // Crucially, the logic below assumes that [previouslyLinkedLeaderOrdinals]
    // was sorted too before.
    _linkedLeaderOrdinals.sort();

    // Look for differences in the two sorted lists of leader ordinals.
    int i = 0, j = 0;
    while (i < previouslyLinkedLeaderOrdinals.length &&
        j < _linkedLeaderOrdinals.length) {
      if (previouslyLinkedLeaderOrdinals[i] < _linkedLeaderOrdinals[j]) {
        // Looks like this previously linked leader ordinal is no longer linked.
        _cogState._runtime.terminateCogStateDependency(
          followerCogStateOrdinal: _cogState.ordinal,
          leaderCogStateOrdinal: previouslyLinkedLeaderOrdinals[i],
        );

        i++;
      } else if (previouslyLinkedLeaderOrdinals[i] > _linkedLeaderOrdinals[j]) {
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
    while (i < previouslyLinkedLeaderOrdinals.length) {
      _cogState._runtime.terminateCogStateDependency(
        followerCogStateOrdinal: _cogState.ordinal,
        leaderCogStateOrdinal: previouslyLinkedLeaderOrdinals[i],
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
  }

  @override
  ValueType get curr {
    if (_hasValue) {
      return _value;
    }

    final init = _cogState.cog.init;
    if (init != null) {
      return init();
    }

    throw StateError(
      'Failed to get current value of automatic Cog '
      '${_cogState.cog} with spin `${_cogState._spin}`: '
      'Cog does not yet have a value, and does not have an accompanying '
      '`init` function',
    );
  }

  @override
  CurrValueType currOr<CurrValueType extends ValueType>(
    CurrValueType fallback,
  ) {
    return _hasValue ? _value as CurrValueType : fallback;
  }

  bool get hasValue => _hasValue;

  @override
  LinkedCogValueType link<LinkedCogValueType, LinkedCogSpinType>(
    Cog<LinkedCogValueType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final acquiredCogState =
        _cogState._runtime.acquire(cog: cog, cogSpin: spin);

    _linkedLeaderOrdinals.add(acquiredCogState.ordinal);

    return acquiredCogState.evaluate();
  }

  @override
  NonCogValueType linkNonCog<NonCogType extends Object, NonCogSubscriptionType,
      NonCogValueType>(
    NonCogType nonCog, {
    required LinkNonCogInit<NonCogType, NonCogValueType> init,
    required LinkNonCogSubscribe<NonCogType, NonCogSubscriptionType,
            NonCogValueType>
        subscribe,
    required LinkNonCogUnsubscribe<NonCogType, NonCogSubscriptionType,
            NonCogValueType>
        unsubscribe,
  }) {
    return _cogState.nonCogTracker.track(
      init: init,
      invocationFrameOrdinal: ordinal,
      nonCog: nonCog,
      subscribe: subscribe,
      unsubscribe: unsubscribe,
    );
  }

  FutureOr<ValueType> open() {
    _hasValue = _cogState._hasValue;

    if (_hasValue) {
      _value = _cogState._value;
    }

    _linkedLeaderOrdinals.clear();

    _cogState._runtime.logging.debug(_cogState, 'invoking cog definition');
    _cogState._runtime.telemetry.recordCogStateRecalculation(_cogState.ordinal);

    return _cogState.cog.def(this);
  }

  @override
  SpinType get spin => _cogState.spinOrThrow;
}
