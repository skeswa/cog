part of 'cog.dart';

/// [AutomaticCog] is the concrete implementation of an Automatic [Cog].
///
/// {@macro cog.blurb}
final class AutomaticCog<ValueType, SpinType> extends Cog<ValueType, SpinType> {
  /// Specifies this automatic [Cog]'s concurrency strategy if [def] returns a
  /// [Future].
  ///
  /// When `null`, [async] falls back to [defaultAsync].
  final Async? async;

  /// Closure that defines this automatic [Cog] by linking other Cogs and/or
  /// external state and returning this automatic [Cog]'s value.
  ///
  /// For more information, see the [Cog] docs.
  final AutomaticCogDefinition<ValueType, SpinType> def;

  /// Returns the initial value of this automatic [Cog].
  ///
  /// This [Function] is only necessary if [def] returns a [Future].
  final CogValueInitializer<ValueType>? init;

  /// Specifies how long it should take for values of this automatic [Cog] to
  /// become stale.
  ///
  /// When `null`, [ttl] is assumed to be ∞.
  final Duration? ttl;

  /// Internal [AutomaticCog] constructor.
  AutomaticCog._(
    this.def, {
    super.debugLabel,
    this.async,
    CogValueComparator<ValueType>? eq,
    this.init,
    CogRegistry? registry,
    super.spin,
    this.ttl,
  }) : super._(eq: eq, registry: registry);

  @override
  CogState<ValueType, SpinType, Cog<ValueType, SpinType>> createState({
    required CogStateOrdinal ordinal,
    required CogRuntime runtime,
    required SpinType? spin,
  }) =>
      AutomaticCogState(
        cog: this,
        ordinal: ordinal,
        runtime: runtime,
        spin: spin,
      );

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

    if (async != null) {
      stringBuffer
        ..write('async: ')
        ..write(async);

      hasParams = true;
    }

    if (debugLabel != null) {
      if (hasParams) {
        stringBuffer.write(', ');
      }

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

/// Closure that defines an automatic [Cog] by linking other Cogs and/or
/// external state and returning the automatic [Cog]'s value.
///
/// For more information, see the [Cog] docs.
typedef AutomaticCogDefinition<ValueType, SpinType> = FutureOr<ValueType>
    Function(AutomaticCogController<ValueType, SpinType>);
