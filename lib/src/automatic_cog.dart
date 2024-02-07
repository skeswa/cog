part of 'cog.dart';

final class AutomaticCog<ValueType, SpinType> extends Cog<ValueType, SpinType> {
  final AutomaticCogDefinition<ValueType, SpinType> def;

  final Duration? ttl;

  AutomaticCog._(
    this.def, {
    super.debugLabel,
    CogValueComparator<ValueType>? eq,
    required super.init,
    CogRegistry? registry,
    super.spin,
    this.ttl,
  }) : super._(eq: eq ?? areCogValuesIdentical, registry: registry);

  @override
  String toString() => 'AutomaticCog<$ValueType'
      '${spin != null ? ', $SpinType' : ''}'
      '>('
      '${ttl != null ? 'ttl: $ttl' : ''}'
      ')';
}

abstract interface class AutomaticCogController<ValueType, SpinType> {
  ValueType get curr;
  SpinType get spin;

  LinkedCogValueType link<LinkedCogValueType, LinkedCogSpinType>(
    Cog<LinkedCogValueType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  });
}

typedef AutomaticCogDefinition<ValueType, SpinType> = FutureOr<ValueType>
    Function(AutomaticCogController<ValueType, SpinType>);
