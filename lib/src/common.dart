import 'cog.dart';

typedef CogOrdinal = int;
typedef CogSpinHash = int;
typedef CogStateDepedencyHash = int;
typedef CogStateHash = int;
typedef CogValueComparator<ValueType> = bool Function(ValueType a, ValueType b);
typedef CogValueInitializer<ValueType> = ValueType Function();
typedef CogStateListeningPostDeactivationCallback = void Function();
typedef CogStateOrdinal = int;
typedef CogStateRevision = int;
typedef CogStateRevisionHash = int;

const CogStateRevisionHash leaderRevisionHashSeed = 7;
const CogStateRevisionHash leaderRevisionHashScalingFactor = 31;
const CogStateRevision initialCogStateRevision = 0;

bool thatSpinsMatch<ValueType, SpinType>(
  Cog<ValueType, SpinType> cog,
  SpinType? spin,
) {
  if (cog.spin == null && spin != null) {
    throw ArgumentError(
      'Cannot specify a spin when linking, reading, or watching a Cog '
      'that does not specify spin type in its definition',
    );
  }

  if (cog.spin != null && spin is! SpinType) {
    throw ArgumentError(
      'Must specify a spin when linking, reading, or watching a Cog '
      'that specifies a spin type in its definition',
    );
  }

  return true;
}
