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
  })  : _currentFrameOrdinal = invocationFrame.ordinal,
        _initialInvocation = invocation,
        _initialInvocationFrame = invocationFrame,
        super._(cogState: cogState);

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

    _cogState._onNextValue(
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

    var didInvocationFrameClose = false;

    try {
      invocationFrame ??= AutomaticCogInvocationFrame(
        cogState: _cogState,
        ordinal: ++_currentFrameOrdinal,
      );

      if (invocation == null) {
        final maybeFuture = invocationFrame.open(base: _lastFrame);

        if (maybeFuture is! Future<ValueType>) {
          throw StateError(
            'Expected a Future<$ValueType> to be returned, '
            'but got a ${maybeFuture.runtimeType} instead',
          );
        }

        invocation = maybeFuture;
      }

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

      _cogState._onNextValue(
        nextValue: invocationResult,
        shouldNotify: shouldNotify,
      );

      invocationFrame.close();

      didInvocationFrameClose = true;

      _lastFrame = invocationFrame;
    } catch (e, stackTrace) {
      _cogState._runtime.handleError(
        cogState: _cogState,
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _activeFrameCount--;

      if (!didInvocationFrameClose) {
        invocationFrame?.abandon();
      }
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
