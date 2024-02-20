part of 'cog_state.dart';

final class ManualCogState<ValueType, SpinType>
    extends CogState<ValueType, SpinType, ManualCog<ValueType, SpinType>> {
  ManualCogState({
    required super.cog,
    required super.ordinal,
    required super.runtime,
    required super.spin,
  });

  @override
  void init() {
    maybeRevise(cog.init(), shouldNotify: false);
  }
}
