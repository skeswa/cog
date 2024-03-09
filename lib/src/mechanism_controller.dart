part of 'mechanism.dart';

abstract interface class MechanismController {
  void onDispose(void Function() disposer);

  ValueType read<ValueType, SpinType>(
    Cog<ValueType, SpinType> cog, {
    SpinType? spin,
  });

  StreamSubscription<ValueType> watch<ValueType, SpinType>(
    Cog<ValueType, SpinType> cog,
    void Function(ValueType) onCogValueChange, {
    Priority priority = Priority.low,
    SpinType? spin,
  });

  void write<ValueType, SpinType>(
    ManualCog<ValueType, SpinType> cog,
    ValueType value, {
    bool quietly = false,
    SpinType? spin,
  });
}
