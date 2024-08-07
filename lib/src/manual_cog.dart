part of 'cog.dart';

/// [ManualCog] is the concrete implementation of a Manual [Cog].
///
/// {@macro cog.blurb}
final class ManualCog<ValueType, SpinType> extends Cog<ValueType, SpinType> {
  /// Returns the initial value of this [Cog].
  final CogValueInitializer<ValueType> init;

  /// Internal [ManualCog] constructor.
  ManualCog._({
    super.debugLabel,
    required CogValueComparator<ValueType>? eq,
    required this.init,
    required CogRegistry? registry,
    required super.spin,
  }) : super._(eq: eq, registry: registry);

  @override
  CogState<ValueType, SpinType, Cog<ValueType, SpinType>> createState({
    required CogStateOrdinal ordinal,
    required CogRuntime runtime,
    required SpinType? spin,
  }) =>
      ManualCogState(
        cog: this,
        ordinal: ordinal,
        runtime: runtime,
        spin: spin,
      );

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

  /// Assigns [value] to the specified [spin] of this [Cog] within the given
  /// [cogtext].
  ///
  /// [quietly] is `true` if this write shouldn't notify listeners if it
  /// changes this [Cog]'s value - defaults to `false`.
  ///
  /// {@macro cog_like.spin}
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
