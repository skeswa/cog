part of 'cog_state.dart';

final class AsyncAutomaticCogStateConveyor<ValueType, SpinType>
    extends AutomaticCogStateConveyor<ValueType, SpinType> {
  var _activeFrameCount = 0;
  int _currentFrameOrdinal;
  final CogValueInitializer<ValueType> _init;
  AutomaticCogInvocationFrame<ValueType, SpinType>? _lastFrame;
  final AutomaticCogStateConveyorErrorCallback<ValueType, SpinType> _onError;
  _ReconveyStatus _reconveyStatus = _ReconveyStatus.unnecessary;

  AsyncAutomaticCogStateConveyor._({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required CogValueInitializer<ValueType> init,
    required Future<ValueType> invocation,
    required AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
    required AutomaticCogStateConveyorErrorCallback<ValueType, SpinType>
        onError,
    required AutomaticCogStateConveyorNextValueCallback<ValueType> onNextValue,
  })  : _currentFrameOrdinal = invocationFrame.ordinal,
        _init = init,
        _onError = onError,
        super._(cogState: cogState, onNextValue: onNextValue) {
    _maybeConvey(
      invocation: invocation,
      invocationFrame: invocationFrame,
      shouldNotify: false,
    );
  }

  @override
  void convey() => _maybeConvey();

  Future<void> _maybeConvey({
    Future<ValueType>? invocation,
    AutomaticCogInvocationFrame<ValueType, SpinType>? invocationFrame,
    bool shouldNotify = true,
  }) async {
    // When scheduling sequentially, all we need to track is whether there
    // should be a re-convey. We schedule re-convey when an active frame is
    // already in progress - that we follow it up once complete.
    if (_cogState.cog.async == Async.sequentially && _activeFrameCount > 0) {
      switch (_reconveyStatus) {
        case _ReconveyStatus.scheduled:
          _cogState._runtime.logging.debug(
            _cogState,
            're-convey is already scheduled',
          );

        default:
          _reconveyStatus = _ReconveyStatus.necessary;
      }

      return;
    }

    _activeFrameCount++;

    try {
      invocationFrame ??= AutomaticCogInvocationFrame._(
        cogState: _cogState,
        init: _init,
        ordinal: ++_currentFrameOrdinal,
      );

      invocation ??= invocationFrame.invoke() as Future<ValueType>;

      final invocationResult = await invocation;

      if (_cogState.cog.async == Async.singularly &&
          invocationFrame.ordinal == _currentFrameOrdinal) {
        _cogState._runtime.logging.debug(
          _cogState,
          'invocation frame was usurped - ignoring result',
          invocationResult,
        );

        return;
      }

      _onNextValue(
        nextValue: invocationResult,
        shouldNotify: shouldNotify,
      );

      _updateCogStateDependencies(
        cogState: _cogState,
        linkedLeaderOrdinals: invocationFrame.linkedLeaderOrdinals,
        previouslyLinkedLeaderOrdinals:
            _lastFrame?.linkedLeaderOrdinals ?? const [],
      );

      _lastFrame = invocationFrame;
    } catch (e, stackTrace) {
      _onError(
        cogState: _cogState,
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _activeFrameCount--;
    }

    if (_reconveyStatus == _ReconveyStatus.necessary) {
      _cogState._runtime.logging.debug(
        _cogState,
        'scheduling re-convey',
      );

      scheduleMicrotask(_onReconvey);

      _reconveyStatus = _ReconveyStatus.scheduled;
    }
  }

  void _onReconvey() {
    switch (_reconveyStatus) {
      case _ReconveyStatus.scheduled:
        _reconveyStatus = _ReconveyStatus.unnecessary;

        _cogState._runtime.logging.debug(_cogState, 're-conveying...');

        _maybeConvey(invocation: null);

      default:
        _cogState._runtime.logging.debug(
          _cogState,
          'skipping scheduled re-convey due to status',
        );
    }
  }
}

enum _ReconveyStatus {
  necessary,
  scheduled,
  unnecessary,
}
