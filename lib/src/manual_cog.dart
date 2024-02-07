part of 'cog.dart';

final class ManualCog<ValueType, SpinType> extends Cog<ValueType, SpinType> {
  ManualCog._({
    super.debugLabel,
    required CogValueComparator<ValueType>? eq,
    required super.init,
    required CogRegistry? registry,
    required super.spin,
  }) : super._(eq: eq ?? areCogValuesIdentical, registry: registry);

  @override
  String toString() => 'AutomaticCog<$ValueType'
      '${spin != null ? ', $SpinType' : ''}'
      '>('
      ')';

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

    final cogValue = cogtext._cogValueRuntime.acquire(cog: this, cogSpin: spin);

    cogValue.maybeRevise(value);
  }
}
