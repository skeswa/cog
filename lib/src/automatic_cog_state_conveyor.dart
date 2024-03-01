part of 'cog_state.dart';

sealed class AutomaticCogStateConveyor<ValueType, SpinType> {
  final AutomaticCogState<ValueType, SpinType> _cogState;

  factory AutomaticCogStateConveyor({
    required AutomaticCogState<ValueType, SpinType> cogState,
  }) {
    final invocationFrame = AutomaticCogInvocationFrame(
      cogState: cogState,
      ordinal: _initialInvocationFrameOrdinal,
    );

    final invocation = invocationFrame.open();

    return invocation is Future<ValueType>
        ? AsyncAutomaticCogStateConveyor._(
            cogState: cogState,
            invocation: invocation,
            invocationFrame: invocationFrame,
          )
        : SyncAutomaticCogStateConveyor._(
            cogState: cogState,
            invocationFrame: invocationFrame,
            invocationResult: invocation,
          );
  }

  AutomaticCogStateConveyor._({
    required AutomaticCogState<ValueType, SpinType> cogState,
  }) : _cogState = cogState;

  void convey({bool shouldForce = false});

  void init();

  bool get isEager;

  bool get propagatesPotentialStaleness;
}

typedef AutomaticCogStateConveyorNextValueCallback<ValueType> = void Function({
  required ValueType nextValue,
  required bool shouldNotify,
});

const _initialInvocationFrameOrdinal = 1;
