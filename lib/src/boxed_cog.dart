part of 'cog_box.dart';

/// Automatic [Cog] that belongs to a [CogBox].
///
/// {@macro cog.blurb}
final class BoxedAutomaticCog<ValueType, SpinType>
    extends BoxedCog<ValueType, SpinType> {
  @override
  final AutomaticCog<ValueType, SpinType> _cog;

  @override
  final CogBox _cogBox;

  /// Internal [BoxedAutomaticCog] constructor.
  BoxedAutomaticCog._(this._cog, this._cogBox);
}

/// [Cog] that belongs to a [CogBox].
///
/// {@macro cog.blurb}
sealed class BoxedCog<ValueType, SpinType>
    implements CogLike<ValueType, SpinType> {
  Cog<ValueType, SpinType> get _cog;

  CogBox get _cogBox;

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

  /// Infers and returns the current value from the specified [spin] of this
  /// [Cog].
  ///
  /// {@macro cog_like.spin}
  ValueType read({SpinType? spin}) {
    assert(_cogBox._notDisposed());

    return _cog.read(_cogBox._cogtext, spin: spin);
  }

  @override
  Spin<SpinType>? get spin => _cog.spin;

  @override
  String toString() => 'Boxed($_cog)';

  /// Returns a [Stream] that emits values from the specified [spin] of this
  /// [Cog] as it changes.
  ///
  /// {@macro cog.watch}
  ///
  /// {@macro cog_like.spin}
  Stream<ValueType> watch({
    Priority? priority,
    SpinType? spin,
  }) {
    assert(_cogBox._notDisposed());

    return _cog.watch(_cogBox._cogtext, priority: priority, spin: spin);
  }
}

/// Manual [Cog] that belongs to a [CogBox].
///
/// {@macro cog.blurb}
final class BoxedManualCog<ValueType, SpinType>
    extends BoxedCog<ValueType, SpinType> {
  @override
  final ManualCog<ValueType, SpinType> _cog;

  @override
  final CogBox _cogBox;

  /// Internal [BoxedManualCog] constructor.
  BoxedManualCog._(this._cog, this._cogBox);

  /// Assigns [value] to the specified [spin] of this [Cog].
  ///
  /// [quietly] is `true` if this write shouldn't notify listeners if it
  /// changes this [Cog]'s value - defaults to `false`.
  ///
  /// {@macro cog_like.spin}
  void write(
    ValueType value, {
    bool quietly = false,
    SpinType? spin,
  }) {
    assert(_cogBox._notDisposed());

    _cog.write(_cogBox._cogtext, value, quietly: quietly, spin: spin);
  }
}
