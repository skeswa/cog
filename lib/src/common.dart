typedef CogOrdinal = int;
typedef CogSpinHash = int;
typedef CogValueComparator<ValueType> = bool Function(ValueType a, ValueType b);
typedef CogValueDepedencyHash = int;
typedef CogValueHash = int;
typedef CogValueInitializer<ValueType> = ValueType Function();
typedef CogValueListeningPostDeactivationCallback = void Function();
typedef CogValueOrdinal = int;
typedef CogValueRevision = int;
typedef CogValueRevisionHash = int;

bool areCogValuesIdentical<CogValue>(CogValue a, CogValue b) => identical(a, b);

const CogValueRevisionHash ancestorRevisionHashSeed = 7;
const CogValueRevisionHash ancestorRevisionHashScalingFactor = 31;
const CogValueRevision initialCogValueRevision = 0;
