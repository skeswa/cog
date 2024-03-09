import 'dart:async';

import 'common.dart';
import 'mechanism.dart';

final class GlobalMechanismRegistry implements MechanismRegistry {
  static final instance = GlobalMechanismRegistry();

  final _mechanisms = <Mechanism>[];

  final _mechanismRegisteredController =
      StreamController<MechanismOrdinal>.broadcast(sync: true);

  @override
  Stream<MechanismOrdinal> get mechanismRegistered =>
      _mechanismRegisteredController.stream;

  @override
  Mechanism operator [](MechanismOrdinal mechanismOrdinal) =>
      _mechanisms[mechanismOrdinal];

  @override
  MechanismOrdinal register(Mechanism mechanism) {
    final ordinal = _mechanisms.length;

    _mechanisms.add(mechanism);

    _mechanismRegisteredController.add(ordinal);

    return ordinal;
  }

  @override
  Iterable<Mechanism> get registeredMechanisms => _mechanisms;
}

abstract interface class MechanismRegistry {
  Stream<MechanismOrdinal> get mechanismRegistered;

  Mechanism operator [](MechanismOrdinal mechanismOrdinal);

  MechanismOrdinal register(Mechanism mechanism);

  Iterable<Mechanism> get registeredMechanisms;
}
