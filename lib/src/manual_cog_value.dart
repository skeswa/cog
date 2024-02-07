part of 'cog_value.dart';

final class ManualCogValue<ValueType, SpinType>
    extends CogValue<ValueType, SpinType, ManualCog<ValueType, SpinType>> {
  ManualCogValue({
    required super.cog,
    required super.ordinal,
    required super.runtime,
    required super.spin,
  });
}
