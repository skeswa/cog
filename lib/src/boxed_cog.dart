part of 'cog_box.dart';

final class BoxedAutomaticCog<ValueType, SpinType>
    extends BoxedCog<ValueType, SpinType> {
  @override
  final AutomaticCog<ValueType, SpinType> _cog;

  @override
  final CogBox _cogBox;

  BoxedAutomaticCog._(this._cog, this._cogBox);

  @override
  Stream<ValueType> watch({
    Priority? priority,
    SpinType? spin,
  }) =>
      _cog.watch(_cogBox._cogtext, priority: priority, spin: spin);
}

sealed class BoxedCog<ValueType, SpinType> {
  Cog<ValueType, SpinType> get _cog;

  CogBox get _cogBox;

  ValueType read({SpinType? spin}) => _cog.read(_cogBox._cogtext, spin: spin);

  Stream<ValueType> watch({
    Priority? priority,
    SpinType? spin,
  }) =>
      _cog.watch(_cogBox._cogtext, priority: priority, spin: spin);
}

final class BoxedManualCog<ValueType, SpinType>
    extends BoxedCog<ValueType, SpinType> {
  @override
  final ManualCog<ValueType, SpinType> _cog;

  @override
  final CogBox _cogBox;

  BoxedManualCog._(this._cog, this._cogBox);
}
