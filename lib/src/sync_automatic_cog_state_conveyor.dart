part of 'cog_state.dart';

final class SyncAutomaticCogStateConveyor<ValueType, SpinType>
    extends AutomaticCogStateConveyor<ValueType, SpinType> {
  AutomaticCogInvocationFrame<ValueType, SpinType> _currentInvocationFrame;
  final ValueType _initialInvocationResult;
  AutomaticCogInvocationFrame<ValueType, SpinType> _pendingInvocationFrame;

  SyncAutomaticCogStateConveyor._({
    required super.cogState,
    required AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
    required ValueType invocationResult,
  })  : _currentInvocationFrame = AutomaticCogInvocationFrame(
          cogState: cogState,
          ordinal: invocationFrame.ordinal + 1,
        ),
        _initialInvocationResult = invocationResult,
        _pendingInvocationFrame = invocationFrame,
        super._();

  @override
  void convey({bool shouldForce = false}) {
    final pendingInvocationFrame = _pendingInvocationFrame;

    try {
      final pendingInvocationResult = pendingInvocationFrame.open();

      if (pendingInvocationResult is! ValueType) {
        throw StateError(
          'Expected a $ValueType to be returned, '
          'but got a ${pendingInvocationResult.runtimeType} instead',
        );
      }

      _cogState._onNextValue(
        nextValue: pendingInvocationResult,
        nextInvocationFrameOrdinal: pendingInvocationFrame.ordinal,
        shouldNotify: true,
      );

      _promoteInvocationFrame(pendingInvocationFrame);
    } catch (e, stackTrace) {
      _cogState._runtime.handleError(
        cogState: _cogState,
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (!_wasInvocationFramePromoted(pendingInvocationFrame)) {
        _abandonInvocationFrame(pendingInvocationFrame);
      }
    }
  }

  @override
  void init() {
    _cogState._onNextValue(
      nextValue: _initialInvocationResult,
      nextInvocationFrameOrdinal: _pendingInvocationFrame.ordinal,
      shouldNotify: false,
    );

    _promoteInvocationFrame(_pendingInvocationFrame);
  }

  @override
  bool get isEager => false;

  @override
  bool get propagatesPotentialStaleness => true;

  void _abandonInvocationFrame(
    AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
  ) {
    _cogState._nonCogTracker?.untrackAll(
      invocationFrameOrdinal: invocationFrame.ordinal,
    );

    invocationFrame._linkedLeaderOrdinals.clear();
  }

  void _promoteInvocationFrame(
    AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
  ) {
    _pendingInvocationFrame.close(
      currentInvocationFrame: _currentInvocationFrame,
    );

    final previousInvocationFrame = _currentInvocationFrame;
    _currentInvocationFrame = invocationFrame;
    _pendingInvocationFrame = previousInvocationFrame;

    _abandonInvocationFrame(previousInvocationFrame);
  }

  bool _wasInvocationFramePromoted(
    AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
  ) =>
      invocationFrame == _currentInvocationFrame;
}
