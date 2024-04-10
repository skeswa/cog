part of 'cog.dart';

abstract interface class CogLike<ValueType, SpinType> {
  CogState<ValueType, SpinType, Cog<ValueType, SpinType>> createState({
    required CogStateOrdinal ordinal,
    required CogRuntime runtime,
    required SpinType? spin,
  });

  CogOrdinal get ordinal;

  Spin<SpinType>? get spin;
}
