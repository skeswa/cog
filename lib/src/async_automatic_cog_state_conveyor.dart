part of 'cog_state.dart';

final class AsyncAutomaticCogStateConveyor<ValueType, SpinType>
    extends AutomaticCogStateConveyor<ValueType, SpinType> {
  var _activeFrameCount = 0;
  int _currentFrameOrdinal;
  final Future<ValueType> _initialInvocation;
  final AutomaticCogInvocationFrame<ValueType, SpinType>
      _initialInvocationFrame;
  AutomaticCogInvocationFrame<ValueType, SpinType>? _lastFrame;
  CogStateRevision? _leaderRevisionHash;
  _ReconveyStatus _reconveyStatus = _ReconveyStatus.unnecessary;
  var _shouldReconveyBeForced = false;

  AsyncAutomaticCogStateConveyor._({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required Future<ValueType> invocation,
    required AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
    required AutomaticCogStateConveyorNextValueCallback<ValueType> onNextValue,
  })  : _currentFrameOrdinal = invocationFrame.ordinal,
        _initialInvocation = invocation,
        _initialInvocationFrame = invocationFrame,
        super._(cogState: cogState, onNextValue: onNextValue) {}

  @override
  void convey({bool shouldForce = false}) =>
      _maybeConvey(shouldForce: shouldForce);

  @override
  void init() {
    final init = _cogState.cog.init;

    if (init == null) {
      throw ArgumentError(
        'Failed to initialize asynchronous automatic Cog ${_cogState.cog} '
        'with spin `${_cogState._spin}`: '
        'asynchronous automatic Cogs require an accompanying `init` function',
      );
    }

    _onNextValue(
      nextValue: init(),
      shouldNotify: false,
    );

    _maybeConvey(
      invocation: _initialInvocation,
      invocationFrame: _initialInvocationFrame,
      shouldNotify: true,
    );
  }

  @override
  bool get isEager => true;

  @override
  bool get propagatesPotentialStaleness => false;

  Future<void> _maybeConvey({
    Future<ValueType>? invocation,
    AutomaticCogInvocationFrame<ValueType, SpinType>? invocationFrame,
    bool shouldForce = false,
    bool shouldNotify = true,
  }) async {
    if (_activeFrameCount > 0) {
      switch (_cogState.cog.async) {
        // When scheduling queued, all we need to track is whether there should
        // be a re-convey. We schedule re-convey when an active frame is
        // already in progress - that we follow it up once complete.
        case Async.queued:
          if (_reconveyStatus != _ReconveyStatus.scheduled) {
            _reconveyStatus = _ReconveyStatus.necessary;
          }
          _shouldReconveyBeForced = _shouldReconveyBeForced || shouldForce;

          _cogState._runtime.logging.debug(
            _cogState,
            're-convey is necessary and might be scheduled already - isForced',
            _shouldReconveyBeForced,
          );

          return;

        case Async.oneAtATime:
          _cogState._runtime.logging.debug(
            _cogState,
            'skipping convey because one is already in progress',
            _shouldReconveyBeForced,
          );

          return;

        default:
          break;
      }
    }

    final latestLeaderRevisionHash = _cogState._calculateLeaderRevisionHash();

    if (!shouldForce && latestLeaderRevisionHash == _leaderRevisionHash) {
      _cogState._runtime.logging.debug(
        _cogState,
        're-convey has already happened for the current revision',
      );

      return;
    }

    _leaderRevisionHash = latestLeaderRevisionHash;

    _activeFrameCount++;

    try {
      invocationFrame ??= AutomaticCogInvocationFrame._(
        cogState: _cogState,
        ordinal: ++_currentFrameOrdinal,
      );

      invocation ??= invocationFrame.invoke() as Future<ValueType>;

      final invocationResult = await invocation;

      if (_cogState.cog.async == Async.latestOnly) {
        if (invocationFrame.ordinal < _currentFrameOrdinal) {
          _cogState._runtime.logging.debug(
            _cogState,
            'invocation frame was usurped - ignoring result',
            invocationResult,
          );

          return;
        }

        _cogState._runtime.logging.debug(
          _cogState,
          'invocation frame not usurped - conveying result',
          invocationResult,
        );
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
      _cogState._runtime.handleError(
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
        _shouldReconveyBeForced = false;

        _cogState._runtime.logging.debug(_cogState, 're-conveying...');

        _maybeConvey(invocation: null, shouldForce: _shouldReconveyBeForced);

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
