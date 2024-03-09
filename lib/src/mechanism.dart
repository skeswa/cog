import 'dart:async';

import 'cog.dart';
import 'common.dart';
import 'mechanism_registry.dart';
import 'priority.dart';

part 'mechanism_controller.dart';

final class Mechanism {
  String? debugLabel;

  final MechanismDefinition def;

  late final MechanismOrdinal ordinal;

  Mechanism(
    this.def, {
    this.debugLabel,
    MechanismRegistry? registry,
  }) {
    ordinal = (registry ?? GlobalMechanismRegistry.instance).register(this);
  }

  void pause(Cogtext cogtext) {
    cogtext.runtime.pauseMechanism(ordinal);
  }

  void resume(Cogtext cogtext) {
    cogtext.runtime.resumeMechanism(ordinal);
  }

  @override
  String toString() => 'Mechanism('
      '${debugLabel != null ? 'debugLabel: "$debugLabel"' : ''}'
      ')';
}

typedef MechanismDefinition = void Function(MechanismController);
