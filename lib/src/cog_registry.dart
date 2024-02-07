import 'cog.dart';
import 'common.dart';

abstract interface class CogRegistry {
  CogOrdinal register<CogStateType, CogSpinType>(
    Cog<CogStateType, CogSpinType> cog,
  );
}

final class GlobalCogRegistry implements CogRegistry {
  static final instance = GlobalCogRegistry();

  final _cogs = <Cog>[];

  @override
  CogOrdinal register<CogStateType, CogSpinType>(
    Cog<CogStateType, CogSpinType> cog,
  ) {
    final ordinal = _cogs.length;

    _cogs.add(cog);

    return ordinal;
  }
}
