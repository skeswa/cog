import 'cog.dart';
import 'common.dart';

abstract interface class CogRegistry {
  Cog operator [](CogOrdinal cogOrdinal);

  CogOrdinal register<CogValueType, CogSpinType>(
    Cog<CogValueType, CogSpinType> cog,
  );

  Iterable<Cog> get registeredCogs;
}

final class GlobalCogRegistry implements CogRegistry {
  static final instance = GlobalCogRegistry();

  final _cogs = <Cog>[];

  GlobalCogRegistry();

  @override
  CogOrdinal register<CogValueType, CogSpinType>(
    Cog<CogValueType, CogSpinType> cog,
  ) {
    final ordinal = _cogs.length;

    _cogs.add(cog);

    return ordinal;
  }

  @override
  Cog operator [](CogOrdinal cogOrdinal) => _cogs[cogOrdinal];

  @override
  Iterable<Cog> get registeredCogs => _cogs;
}
