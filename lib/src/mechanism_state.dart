import 'dart:async';

import 'cog.dart';
import 'cog_runtime.dart';
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
  StreamSubscription<ValueType> onChange<ValueType, SpinType>(
    Cog<ValueType, SpinType> cog,
    void Function(ValueType) onCogValueChange, {
    Priority priority = Priority.low,
    SpinType? spin,
  }) {
    final valueChangeSubscription = cog
        .watch(this, priority: priority, spin: spin)
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
