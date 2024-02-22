part of 'cog.dart';

abstract interface class AutomaticCogController<ValueType, SpinType> {
  ValueType get curr;

  CurrValueType currOr<CurrValueType extends ValueType>(
    CurrValueType fallback,
  );

  SpinType get spin;

  LinkedCogStateType link<LinkedCogStateType, LinkedCogSpinType>(
    Cog<LinkedCogStateType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  });
}
