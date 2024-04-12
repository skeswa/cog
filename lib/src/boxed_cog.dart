part of 'cog_box.dart';

final class BoxedAutomaticCog<ValueType, SpinType>
    extends BoxedCog<ValueType, SpinType> {
  @override
  final AutomaticCog<ValueType, SpinType> _cog;

  @override
  final CogBox _cogBox;

  BoxedAutomaticCog._(this._cog, this._cogBox);
}

sealed class BoxedCog<ValueType, SpinType>
    implements CogLike<ValueType, SpinType> {
  Cog<ValueType, SpinType> get _cog;

  CogBox get _cogBox;

  var _isDisposed = false;

  @override
  CogState<ValueType, SpinType, Cog<ValueType, SpinType>> createState({
    required CogStateOrdinal ordinal,
    required CogRuntime runtime,
    required SpinType? spin,
  }) =>
      _cog.createState(ordinal: ordinal, runtime: runtime, spin: spin);

  @override
  String? get debugLabel => _cog.debugLabel;

  @override
  CogValueComparator<ValueType>? get eq => _cog.eq;

  @override
  CogOrdinal get ordinal => _cog.ordinal;

  ValueType read({SpinType? spin}) {
    assert(_notDisposed());

    return _cog.read(_cogBox._cogtext, spin: spin);
  }

  @override
  Spin<SpinType>? get spin => _cog.spin;

  @override
  String toString() => 'Boxed($_cog)';

  Stream<ValueType> watch({
    Priority? priority,
    SpinType? spin,
  }) {
    assert(_notDisposed());

    return _cog.watch(_cogBox._cogtext, priority: priority, spin: spin);
  }

  bool _notDisposed() {
    if (_isDisposed) {
      throw StateError('This $this has been disposed');
    }

    return true;
  }
}

final class BoxedManualCog<ValueType, SpinType>
    extends BoxedCog<ValueType, SpinType> {
  @override
  final ManualCog<ValueType, SpinType> _cog;

  @override
  final CogBox _cogBox;

  BoxedManualCog._(this._cog, this._cogBox);

  void write(
    ValueType value, {
    bool quietly = false,
    SpinType? spin,
  }) {
    assert(_notDisposed());

    _cog.write(_cogBox._cogtext, value, quietly: quietly, spin: spin);
  }
}
