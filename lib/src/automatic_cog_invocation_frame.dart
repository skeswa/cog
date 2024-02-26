part of 'cog_state.dart';

final class AutomaticCogInvocationFrame<ValueType, SpinType>
    implements AutomaticCogController<ValueType, SpinType> {
  final AutomaticCogState<ValueType, SpinType> cogState;
  final int ordinal;

  bool _hasValue;
  var _linkedLeaderOrdinals = <CogStateOrdinal>[];
  late ValueType _value;

  AutomaticCogInvocationFrame._({
    required this.cogState,
    required this.ordinal,
  }) : _hasValue = cogState._hasValue {
    if (_hasValue) {
      _value = cogState._value;
    } else {
      final init = cogState.cog.init;

      if (init != null) {
        _value = init();
      }
    }
  }

  @override
  ValueType get curr {
    if (hasValue) {
      return _value;
    }

    final init = cogState.cog.init;
    if (init != null) {
      return init();
    }

    throw StateError(
      'Failed to get current value of automatic Cog '
      '${cogState.cog} with spin `${cogState._spin}`: '
      'Cog does not yet have a value, and does not have an accompanying '
      '`init` function',
    );
  }

  @override
  CurrValueType currOr<CurrValueType extends ValueType>(
    CurrValueType fallback,
  ) {
    return hasValue ? _value as CurrValueType : fallback;
  }

  FutureOr<ValueType> invoke() {
    cogState._runtime.logging.debug(cogState, 'invoking cog definition');
    cogState._runtime.telemetry.recordCogStateRecalculation(cogState.ordinal);

    return cogState.cog.def(this);
  }

  bool get hasValue => _hasValue;

  @override
  LinkedCogStateType link<LinkedCogStateType, LinkedCogSpinType>(
    Cog<LinkedCogStateType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final acquiredCogState = cogState._runtime.acquire(cog: cog, cogSpin: spin);

    _linkedLeaderOrdinals.add(acquiredCogState.ordinal);

    return acquiredCogState.evaluate();
  }

  List<CogStateOrdinal> get linkedLeaderOrdinals => _linkedLeaderOrdinals;

  void reset({
    List<CogStateOrdinal>? linkedLeaderOrdinals,
  }) {
    if (linkedLeaderOrdinals != null) {
      _linkedLeaderOrdinals = linkedLeaderOrdinals;
    }

    _hasValue = cogState._hasValue;
    if (_hasValue) {
      _value = cogState._value;
    }
  }

  @override
  SpinType get spin => cogState.spinOrThrow;
}
