part of 'cog.dart';

final class AutomaticCog<ValueType, SpinType> extends Cog<ValueType, SpinType> {
  final AutomaticCogDefinition<ValueType, SpinType> def;

  final Duration? ttl;

  AutomaticCog._(
    this.def, {
    super.debugLabel,
    CogStateComparator<ValueType>? eq,
    required super.init,
    CogRegistry? registry,
    super.spin,
    this.ttl,
  }) : super._(eq: eq ?? identical, registry: registry);

  @override
  String toString() {
    final stringBuffer = StringBuffer('AutomaticCog<')..write(ValueType);

    if (spin != null) {
      stringBuffer
        ..write(', ')
        ..write(SpinType);
    }

    stringBuffer.write('>(');

    var hasParams = false;

    if (debugLabel != null) {
      stringBuffer
        ..write('debugLabel: "')
        ..write(debugLabel)
        ..write('"');

      hasParams = true;
    }

    if (eq != identical) {
      if (hasParams) {
        stringBuffer.write(', ');
      }

      stringBuffer.write('eq: overridden');

      hasParams = true;
    }

    if (ttl != null) {
      if (hasParams) {
        stringBuffer.write(', ');
      }

      stringBuffer
        ..write('ttl: ')
        ..write(ttl);

      hasParams = true;
    }

    stringBuffer.write(')');

    return stringBuffer.toString();
  }
}

abstract interface class AutomaticCogController<ValueType, SpinType> {
  ValueType get curr;
  SpinType get spin;

  LinkedCogStateType link<LinkedCogStateType, LinkedCogSpinType>(
    Cog<LinkedCogStateType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  });
}

typedef AutomaticCogDefinition<ValueType, SpinType> = FutureOr<ValueType>
    Function(AutomaticCogController<ValueType, SpinType>);
