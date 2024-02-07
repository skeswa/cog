typedef CogOrdinal = int;
typedef CogSpinHash = int;
typedef CogStateComparator<ValueType> = bool Function(ValueType a, ValueType b);
typedef CogStateDepedencyHash = int;
typedef CogStateHash = int;
typedef CogStateInitializer<ValueType> = ValueType Function();
typedef CogStateListeningPostDeactivationCallback = void Function();
typedef CogStateOrdinal = int;
typedef CogStateRevision = int;
typedef CogStateRevisionHash = int;

bool areCogStatesIdentical<CogState>(CogState a, CogState b) => identical(a, b);

const CogStateRevisionHash leaderRevisionHashSeed = 7;
const CogStateRevisionHash leaderRevisionHashScalingFactor = 31;
const CogStateRevision initialCogStateRevision = 0;
