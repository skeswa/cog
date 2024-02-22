part of 'cog.dart';

final class AutomaticCog<ValueType, SpinType> extends Cog<ValueType, SpinType> {
  final Async async;

  final AutomaticCogDefinition<ValueType, SpinType> def;

  final CogValueInitializer<ValueType>? init;

  final Duration? ttl;

  AutomaticCog._(
    this.def, {
    super.debugLabel,
    Async? async,
    CogValueComparator<ValueType>? eq,
    this.init,
    CogRegistry? registry,
    super.spin,
    this.ttl,
  })  : async = async ?? Async.inParallel,
        super._(eq: eq ?? identical, registry: registry);

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

typedef AutomaticCogDefinition<ValueType, SpinType> = FutureOr<ValueType>
    Function(AutomaticCogController<ValueType, SpinType>);
