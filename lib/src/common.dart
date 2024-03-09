import 'cog.dart';

typedef AutomaticCogInvocationFrameOrdinal = int;
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
typedef MechanismOrdinal = int;
typedef TrackedNonCogRevision = int;
typedef TrackedNonCogRevisionHash = int;

const CogStateRevision initialCogStateRevision = 0;
const TrackedNonCogRevision initialTrackedNonCogRevision = 0;
const revisionHashSeed = 7;
const revisionHashScalingFactor = 31;

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
