part of 'cog_state.dart';

sealed class AutomaticCogStateConveyor<ValueType, SpinType> {
  final AutomaticCogState<ValueType, SpinType> _cogState;

  final AutomaticCogStateConveyorNextValueCallback<ValueType> _onNextValue;

  factory AutomaticCogStateConveyor({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required AutomaticCogStateConveyorNextValueCallback<ValueType> onNextValue,
  }) {
    final invocationFrame = AutomaticCogInvocationFrame._(
      cogState: cogState,
      ordinal: _initialInvocationFrameOrdinal,
    );

    final invocation = invocationFrame.invoke();

    return invocation is Future<ValueType>
        ? AsyncAutomaticCogStateConveyor._(
            cogState: cogState,
            invocation: invocation,
            invocationFrame: invocationFrame,
            onNextValue: onNextValue,
          )
        : SyncAutomaticCogStateConveyor._(
            cogState: cogState,
            invocationFrame: invocationFrame,
            invocationResult: invocation,
            onNextValue: onNextValue,
          );
  }

  AutomaticCogStateConveyor._({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required AutomaticCogStateConveyorNextValueCallback<ValueType> onNextValue,
  })  : _cogState = cogState,
        _onNextValue = onNextValue;

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

void _updateCogStateDependencies<ValueType, SpinType>({
  required AutomaticCogState<ValueType, SpinType> cogState,
  required List<CogStateOrdinal> linkedLeaderOrdinals,
  required List<CogStateOrdinal> previouslyLinkedLeaderOrdinals,
}) {
  // Ensure that the linked ordinals are in order so we can compare to
  // previously linked leader ordinals.
  //
  // Crucially, the logic below assumes that [previouslyLinkedLeaderOrdinals]
  // was sorted too before.
  linkedLeaderOrdinals.sort();

  // Look for differences in the two sorted lists of leader ordinals.
  int i = 0, j = 0;
  while (i < previouslyLinkedLeaderOrdinals.length &&
      j < linkedLeaderOrdinals.length) {
    if (previouslyLinkedLeaderOrdinals[i] < linkedLeaderOrdinals[j]) {
      // Looks like this previously linked leader ordinal is no longer linked.
      cogState._runtime.terminateCogStateDependency(
        followerCogStateOrdinal: cogState.ordinal,
        leaderCogStateOrdinal: previouslyLinkedLeaderOrdinals[i],
      );

      i++;
    } else if (previouslyLinkedLeaderOrdinals[i] > linkedLeaderOrdinals[j]) {
      // Looks like we have a newly linked leader ordinal.
      cogState._runtime.renewCogStateDependency(
        followerCogStateOrdinal: cogState.ordinal,
        leaderCogStateOrdinal: linkedLeaderOrdinals[j],
      );

      j++;
    } else {
      // This leader ordinal has stayed linked.

      i++;
      j++;
    }
  }

  // We need to account for one of the lists being longer than the other.
  while (i < previouslyLinkedLeaderOrdinals.length) {
    cogState._runtime.terminateCogStateDependency(
      followerCogStateOrdinal: cogState.ordinal,
      leaderCogStateOrdinal: previouslyLinkedLeaderOrdinals[i],
    );

    i++;
  }
  while (j < linkedLeaderOrdinals.length) {
    cogState._runtime.renewCogStateDependency(
      followerCogStateOrdinal: cogState.ordinal,
      leaderCogStateOrdinal: linkedLeaderOrdinals[j],
    );

    j++;
  }
}
