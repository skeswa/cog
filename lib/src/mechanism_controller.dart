part of 'mechanism.dart';

abstract interface class MechanismController implements Cogtext {
  StreamSubscription<ValueType> onChange<ValueType, SpinType>(
    CogLike<ValueType, SpinType> cog,
    void Function(ValueType) onCogValueChange, {
    Priority priority = Priority.low,
    SpinType? spin,
  });

  void onDispose(void Function() disposer);
}
