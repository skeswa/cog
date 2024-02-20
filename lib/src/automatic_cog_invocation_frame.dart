part of 'cog_state.dart';

final class AutomaticCogInvocationFrame<ValueType, SpinType>
    implements AutomaticCogController<ValueType, SpinType> {
  final AutomaticCogState<ValueType, SpinType> cogState;
  final bool hasValue;
  var linkedLeaderOrdinals = <CogStateOrdinal>[];
  final int ordinal;
  late ValueType value;

  AutomaticCogInvocationFrame._({
    required this.cogState,
    required CogValueInitializer<ValueType>? init,
    required this.ordinal,
  }) : hasValue = cogState._hasValue {
    if (hasValue) {
      value = cogState._value;
    } else if (init != null) {
      value = init();
    }
  }

  @override
  CurrValueType curr<CurrValueType extends ValueType>(CurrValueType orElse) =>
      hasValue ? value as CurrValueType : orElse;

  FutureOr<ValueType> invoke() {
    cogState._runtime.logging.debug(cogState, 'invoking cog definition');
    cogState._runtime.telemetry.recordCogStateRecalculation(cogState.ordinal);

    return cogState.cog.def(this);
  }

  @override
  LinkedCogStateType link<LinkedCogStateType, LinkedCogSpinType>(
    Cog<LinkedCogStateType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final acquiredCogState = cogState._runtime.acquire(cog: cog, cogSpin: spin);

    linkedLeaderOrdinals.add(acquiredCogState.ordinal);

    return acquiredCogState.evaluate();
  }

  @override
  SpinType get spin => cogState.spinOrThrow;
}
