import 'dart:async';

import 'cog.dart';
import 'cog_runtime.dart';
import 'common.dart';
import 'mechanism.dart';
import 'priority.dart';

final class MechanismState implements MechanismController {
  final Mechanism mechanism;

  final CogRuntime _cogRuntime;
  final _disposers = <void Function()>[];

  MechanismState({
    required CogRuntime cogRuntime,
    required this.mechanism,
  }) : _cogRuntime = cogRuntime;

  void dispose() {
    for (final disposer in _disposers) {
      try {
        disposer();
      } catch (e, stackTrace) {
        _cogRuntime.handleError(
          error: StateError(
            'Failed to execute a disposer for Mechanism $mechanism: e',
          ),
          mechanism: mechanism,
          stackTrace: stackTrace,
        );
      }
    }

    _disposers.clear();
  }

  void init() {
    try {
      mechanism.def(this);
    } catch (e, stackTrace) {
      _cogRuntime.handleError(
        error: StateError(
          'Failed to initialize Mechanism $mechanism: e',
        ),
        mechanism: mechanism,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void onDispose(void Function() disposer) {
    if (_disposers.contains(disposer)) {
      return;
    }

    _disposers.add(disposer);
  }

  @override
  ValueType read<ValueType, SpinType>(
    Cog<ValueType, SpinType> cog, {
    SpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final cogState = _cogRuntime.acquire(cog: cog, cogSpin: spin);

    return cogState.evaluate();
  }

  @override
  StreamSubscription<ValueType> watch<ValueType, SpinType>(
    Cog<ValueType, SpinType> cog,
    void Function(ValueType) onCogValueChange, {
    Priority priority = Priority.low,
    SpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final cogState = _cogRuntime.acquire(cog: cog, cogSpin: spin);

    final valueChangeStream = _cogRuntime.acquireValueChangeStream(
      cogState: cogState,
      priority: priority,
    );

    final valueChangeSubscription = valueChangeStream.listen(onCogValueChange);

    onDispose(valueChangeSubscription.cancel);

    return valueChangeSubscription;
  }

  @override
  void write<ValueType, SpinType>(
    ManualCog<ValueType, SpinType> cog,
    ValueType value, {
    bool quietly = false,
    SpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final cogState = _cogRuntime.acquire(cog: cog, cogSpin: spin);

    cogState.maybeRevise(value, shouldNotify: !quietly);
  }
}
