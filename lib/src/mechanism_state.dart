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

  @override
  String? get debugLabel => mechanism.debugLabel != null
      ? 'MechanismController(debugLabel: "${mechanism.debugLabel}")'
      : null;

  @override
  FutureOr<void> dispose() {
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

  bool init() {
    try {
      mechanism.def(this);

      return true;
    } catch (e, stackTrace) {
      _cogRuntime.handleError(
        error: StateError(
          'Failed to initialize Mechanism $mechanism: e',
        ),
        mechanism: mechanism,
        stackTrace: stackTrace,
      );
    }

    return false;
  }

  @override
  StreamSubscription<ValueType> onChange<ValueType, SpinType>(
    CogLike<ValueType, SpinType> cog,
    void Function(ValueType) onCogValueChange, {
    Priority priority = Priority.low,
    SpinType? spin,
  }) {
    assert(thatSpinsMatch(cog, spin));

    final cogState = _cogRuntime.acquire(cog: cog, cogSpin: spin);

    final valueChangeSubscription = _cogRuntime
        .acquireValueChangeStream(
          cogState: cogState,
          priority: priority,
        )
        .listen(onCogValueChange);

    onDispose(valueChangeSubscription.cancel);

    return valueChangeSubscription;
  }

  @override
  void onDispose(void Function() disposer) {
    if (_disposers.contains(disposer)) {
      return;
    }

    _disposers.add(disposer);
  }

  @override
  CogRuntime get runtime => _cogRuntime;
}
