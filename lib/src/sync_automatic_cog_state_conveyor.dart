part of 'cog_state.dart';

final class SyncAutomaticCogStateConveyor<ValueType, SpinType>
    extends AutomaticCogStateConveyor<ValueType, SpinType> {
  final AutomaticCogInvocationFrame<ValueType, SpinType> _invocationFrame;
  final AutomaticCogStateConveyorErrorCallback<ValueType, SpinType> _onError;

  var _previouslyLinkedLeaderOrdinals = <CogStateOrdinal>[];

  SyncAutomaticCogStateConveyor._({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
    required ValueType invocationResult,
    required AutomaticCogStateConveyorErrorCallback<ValueType, SpinType>
        onError,
    required AutomaticCogStateConveyorNextValueCallback<ValueType> onNextValue,
  })  : _invocationFrame = invocationFrame,
        _onError = onError,
        super._(cogState: cogState, onNextValue: onNextValue) {
    _onNextValue(
      nextValue: invocationResult,
      shouldNotify: false,
    );
  }

  @override
  void convey({bool quietly = false}) {
    _resetInvocationFrame();

    try {
      final invocationResult = _invocationFrame.invoke() as ValueType;

      _updateCogStateDependencies(
        cogState: _cogState,
        linkedLeaderOrdinals: _invocationFrame.linkedLeaderOrdinals,
        previouslyLinkedLeaderOrdinals: _previouslyLinkedLeaderOrdinals,
      );

      _onNextValue(
        nextValue: invocationResult,
        shouldNotify: !quietly,
      );
    } catch (e, stackTrace) {
      _onError(
        cog: _cogState.cog,
        error: e,
        spin: _cogState._spin,
        stackTrace: stackTrace,
      );
    }
  }

  void _resetInvocationFrame() {
    final previouslyLinkedLeaderOrdinals = _previouslyLinkedLeaderOrdinals;

    _previouslyLinkedLeaderOrdinals = _invocationFrame.linkedLeaderOrdinals;

    _invocationFrame.linkedLeaderOrdinals = previouslyLinkedLeaderOrdinals
      ..clear();
  }
}
