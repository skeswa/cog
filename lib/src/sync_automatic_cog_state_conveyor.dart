part of 'cog_state.dart';

final class SyncAutomaticCogStateConveyor<ValueType, SpinType>
    extends AutomaticCogStateConveyor<ValueType, SpinType> {
  final ValueType _initialInvocationResult;
  final AutomaticCogInvocationFrame<ValueType, SpinType> _invocationFrame;

  var _previouslyLinkedLeaderOrdinals = <CogStateOrdinal>[];

  SyncAutomaticCogStateConveyor._({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
    required ValueType invocationResult,
    required AutomaticCogStateConveyorNextValueCallback<ValueType> onNextValue,
  })  : _initialInvocationResult = invocationResult,
        _invocationFrame = invocationFrame,
        super._(cogState: cogState, onNextValue: onNextValue) {}

  @override
  void convey({bool shouldForce = false}) {
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
        shouldNotify: true,
      );
    } catch (e, stackTrace) {
      _cogState._runtime.handleError(
        cogState: _cogState,
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  void init() {
    _updateCogStateDependencies(
      cogState: _cogState,
      linkedLeaderOrdinals: _invocationFrame.linkedLeaderOrdinals,
      previouslyLinkedLeaderOrdinals: _previouslyLinkedLeaderOrdinals,
    );

    _onNextValue(
      nextValue: _initialInvocationResult,
      shouldNotify: false,
    );
  }

  @override
  bool get isEager => false;

  @override
  bool get propagatesPotentialStaleness => true;

  void _resetInvocationFrame() {
    final previouslyLinkedLeaderOrdinals = _previouslyLinkedLeaderOrdinals;

    _previouslyLinkedLeaderOrdinals = _invocationFrame.linkedLeaderOrdinals;

    _invocationFrame.reset(
      linkedLeaderOrdinals: previouslyLinkedLeaderOrdinals..clear(),
    );
  }
}
