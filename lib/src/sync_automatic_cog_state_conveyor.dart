part of 'cog_state.dart';

final class SyncAutomaticCogStateConveyor<ValueType, SpinType>
    extends AutomaticCogStateConveyor<ValueType, SpinType> {
  final ValueType _initialInvocationResult;
  AutomaticCogInvocationFrame<ValueType, SpinType> _invocationFrame;
  AutomaticCogInvocationFrame<ValueType, SpinType>? _previousInvocationFrame;

  SyncAutomaticCogStateConveyor._({
    required super.cogState,
    required AutomaticCogInvocationFrame<ValueType, SpinType> invocationFrame,
    required ValueType invocationResult,
  })  : _initialInvocationResult = invocationResult,
        _invocationFrame = invocationFrame,
        super._();

  @override
  void convey({bool shouldForce = false}) {
    _swapInvocationFrames();

    var didInvocationFrameClose = false;

    try {
      final invocationResult =
          _invocationFrame.open(base: _previousInvocationFrame);

      if (invocationResult is! ValueType) {
        throw StateError(
          'Expected a $ValueType to be returned, '
          'but got a ${invocationResult.runtimeType} instead',
        );
      }

      _cogState._onNextValue(
        nextValue: invocationResult,
        shouldNotify: true,
      );

      _invocationFrame.close();

      didInvocationFrameClose = true;
    } catch (e, stackTrace) {
      _cogState._runtime.handleError(
        cogState: _cogState,
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (!didInvocationFrameClose) {
        _invocationFrame.abandon();
      }
    }
  }

  @override
  void init() {
    _cogState._onNextValue(
      nextValue: _initialInvocationResult,
      shouldNotify: false,
    );

    // The initial invocation frame arrived "pre-opened", so we need to close it
    // once an initial value has been reported to Cog state.
    _invocationFrame.close();
  }

  @override
  bool get isEager => false;

  @override
  bool get propagatesPotentialStaleness => true;

  void _swapInvocationFrames() {
    final nextInvocationFrame = _previousInvocationFrame ??
        AutomaticCogInvocationFrame(
          cogState: _cogState,
          ordinal: _invocationFrame.ordinal + 1,
        );

    _previousInvocationFrame = _invocationFrame;
    _invocationFrame = nextInvocationFrame;
  }
}
