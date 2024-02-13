part of 'cog.dart';

final class ManualCog<ValueType, SpinType> extends Cog<ValueType, SpinType> {
  final CogValueInitializer<ValueType> init;

  ManualCog._({
    super.debugLabel,
    required CogValueComparator<ValueType>? eq,
    required this.init,
    required CogRegistry? registry,
    required super.spin,
  }) : super._(eq: eq ?? identical, registry: registry);

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

    if (eq != identical) {
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
    SpinType? spin,
  }) {
    assert(() {
      if (this.spin == null && spin != null) {
        throw ArgumentError(
          'Cannot write with spin to a Cog that '
          'does not specify a spin in its definition',
        );
      }

      if (this.spin != null && spin == null) {
        throw ArgumentError(
          'Cannot write without spin to a Cog that '
          'does specifies a spin in its definition',
        );
      }

      return true;
    }());

    final cogState = cogtext._cogStateRuntime.acquire(cog: this, cogSpin: spin);

    cogState.maybeRevise(value);
  }
}
