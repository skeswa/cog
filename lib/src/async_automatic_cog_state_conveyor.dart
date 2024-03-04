part of 'cog_state.dart';

final class AsyncAutomaticCogStateConveyor<ValueType, SpinType>
    extends AutomaticCogStateConveyor<ValueType, SpinType> {
  AutomaticCogInvocationFrame<ValueType, SpinType>? _currentInvocationFrame;
  final Future<ValueType> _initialInvocation;
  final AutomaticCogInvocationFrame<ValueType, SpinType>
      _initialInvocationFrame;
  CogStateRevision? _leaderRevisionHash;
  AutomaticCogInvocationFrameOrdinal _nextInvocationFrameOrdinal;
  var _pendingInvocationFrameCount = 0;
  _ReconveyStatus _reconveyStatus = _ReconveyStatus.unnecessary;
  var _shouldReconveyBeForced = false;

  AsyncAutomaticCogStateConveyor._({
    required AutomaticCogState<ValueType, SpinType> cogState,
    required Future<ValueType> invocation,
    required AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
  })  : _initialInvocation = invocation,
        _initialInvocationFrame = invocationFrame,
        _nextInvocationFrameOrdinal = invocationFrame.ordinal + 1,
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
      nextInvocationFrameOrdinal: _initialInvocationFrame.ordinal - 1,
      nextValue: init(),
      shouldNotify: false,
    );

    _maybeConvey(
      pendingInvocation: _initialInvocation,
      pendingInvocationFrame: _initialInvocationFrame,
      shouldNotify: true,
    );
  }

  @override
  bool get isEager => true;

  @override
  bool get propagatesPotentialStaleness => false;

  void _abandonInvocationFrame(
    AutomaticCogInvocationFrame<ValueType, SpinType>? invocationFrame,
  ) {
    _cogState._nonCogTracker?.untrackAll(
      invocationFrameOrdinal: invocationFrame?.ordinal,
    );
  }

  bool _isLatestInvocationFrame(
    AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
  ) =>
      _nextInvocationFrameOrdinal - invocationFrame.ordinal <= 1;

  Future<void> _maybeConvey({
    Future<ValueType>? pendingInvocation,
    AutomaticCogInvocationFrame<ValueType, SpinType>? pendingInvocationFrame,
    bool shouldForce = false,
    bool shouldNotify = true,
  }) async {
    if (_pendingInvocationFrameCount > 0) {
      switch (_cogState.cog.async) {
        case Async.oneAtATime:
          _cogState._runtime.logging.debug(
            _cogState,
            'skipping convey because one is already in progress',
            _shouldReconveyBeForced,
          );

          return;

        // When scheduling queued, all we need to track is whether there should
        // be a re-convey. We schedule re-convey when an active frame is already
        // in progress so that we can follow it up once complete.
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
    _pendingInvocationFrameCount++;

    try {
      pendingInvocationFrame ??= AutomaticCogInvocationFrame(
        cogState: _cogState,
        ordinal: _nextInvocationFrameOrdinal++,
      );

      if (pendingInvocation == null) {
        final maybeFuture = pendingInvocationFrame.open();

        if (maybeFuture is! Future<ValueType>) {
          throw StateError(
            'Expected a Future<$ValueType> to be returned, '
            'but got a ${maybeFuture.runtimeType} instead',
          );
        }

        pendingInvocation = maybeFuture;
      }

      final pendingInvocationResult = await pendingInvocation;

      if (_cogState.cog.async == Async.latestOnly) {
        if (!_isLatestInvocationFrame(pendingInvocationFrame)) {
          _cogState._runtime.logging.debug(
            _cogState,
            'pending invocation frame was usurped - ignoring result',
            pendingInvocationResult,
          );

          return;
        }

        _cogState._runtime.logging.debug(
          _cogState,
          'pending invocation frame not usurped - conveying result',
          pendingInvocationResult,
        );
      }

      _cogState._onNextValue(
        nextInvocationFrameOrdinal: pendingInvocationFrame.ordinal,
        nextValue: pendingInvocationResult,
        shouldNotify: shouldNotify,
      );

      _promoteInvocationFrame(pendingInvocationFrame);
    } catch (e, stackTrace) {
      _cogState._runtime.handleError(
        cogState: _cogState,
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _pendingInvocationFrameCount--;

      if (!_wasInvocationFramePromoted(pendingInvocationFrame)) {
        _abandonInvocationFrame(pendingInvocationFrame);
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

        _maybeConvey(shouldForce: _shouldReconveyBeForced);

      default:
        _cogState._runtime.logging.debug(
          _cogState,
          'skipping scheduled re-convey due to status',
        );
    }
  }

  void _promoteInvocationFrame(
    AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
  ) {
    invocationFrame.close(
      currentInvocationFrame: _currentInvocationFrame,
    );

    final previousInvocationFrame = _currentInvocationFrame;
    _currentInvocationFrame = invocationFrame;

    _abandonInvocationFrame(previousInvocationFrame);
  }

  bool _wasInvocationFramePromoted(
    AutomaticCogInvocationFrame<ValueType, SpinType>? invocationFrame,
  ) =>
      invocationFrame == _currentInvocationFrame;
}

enum _ReconveyStatus {
  necessary,
  scheduled,
  unnecessary,
}
