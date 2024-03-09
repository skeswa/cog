part of 'cog.dart';

final class ManualCog<ValueType, SpinType> extends Cog<ValueType, SpinType> {
  final CogValueInitializer<ValueType> init;

  ManualCog._({
    super.debugLabel,
    required CogValueComparator<ValueType>? eq,
    required this.init,
    required CogRegistry? registry,
    required super.spin,
  }) : super._(eq: eq, registry: registry);

  @override
  String toString() {
    final stringBuffer = StringBuffer('ManualCog<')..write(ValueType);

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

    if (eq != null) {
      if (hasParams) {
        stringBuffer.write(', ');
      }

      stringBuffer.write('eq: overridden');

      hasParams = true;
    }

    stringBuffer.write(')');

    return stringBuffer.toString();
  }

  void write(
    Cogtext cogtext,
    ValueType value, {
    bool quietly = false,
    SpinType? spin,
  }) {
    assert(thatSpinsMatch(this, spin));

    final cogState = cogtext.runtime.acquire(cog: this, cogSpin: spin);

    cogState.maybeRevise(value, shouldNotify: !quietly);
  }
}
